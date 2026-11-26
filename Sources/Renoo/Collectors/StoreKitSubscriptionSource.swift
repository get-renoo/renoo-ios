import Foundation
import StoreKit

/// Where the subscription collector gets its facts. The real one is StoreKit 2; tests use a fake.
protocol SubscriptionSource: AnyObject, Sendable {
    /// Every auto-renewable subscription the user has, with renewal status. `knownGroupIds` are
    /// groups seen before, so subscriptions that already left `currentEntitlements` are still read.
    func subscriptions(knownGroupIds: Set<String>) async -> [SubscriptionFacts]
    /// New transactions, for the whole process lifetime.
    func transactionUpdates() -> AsyncStream<TransactionFacts>
    /// One element per subscription status change, for the whole process lifetime. Covers what
    /// `Transaction.updates` never delivers: purchases the app makes with `Product.purchase()`
    /// and auto-renew changes.
    func statusUpdates() -> AsyncStream<Void>
}

/// StoreKit 2, observe only: never finishes a transaction, never starts a purchase.
final class StoreKitSubscriptionSource: SubscriptionSource, @unchecked Sendable {
    /// After this, a status request that hasn't answered is abandoned and the entitlement alone is used.
    static let statusTimeout: TimeInterval = 5

    private let logger: SDKLogger

    init(logger: SDKLogger) { self.logger = logger }

    func subscriptions(knownGroupIds: Set<String>) async -> [SubscriptionFacts] {
        var entitlements: [TransactionFacts] = []
        for await result in Transaction.currentEntitlements {
            let transaction = payload(result)
            guard transaction.productType == .autoRenewable else { continue }
            entitlements.append(Self.facts(from: transaction))
        }

        let groups = knownGroupIds.union(entitlements.compactMap(\.groupId))
        var subscriptions: [SubscriptionFacts] = []
        for group in groups.sorted() {
            let statuses = await Self.withTimeout(Self.statusTimeout) { [self] () -> [SubscriptionFacts] in
                try await Product.SubscriptionInfo.status(for: group).map { facts(from: $0, groupId: group) }
            }
            if let statuses, !statuses.isEmpty {
                subscriptions += statuses
            } else {
                if statuses == nil { logger.info("subscription status for group \(group) unavailable; using entitlements") }
                subscriptions += entitlements
                    .filter { $0.groupId == group }
                    .map { SubscriptionFacts(transaction: $0, renewalState: nil, willAutoRenew: nil) }
            }
        }
        // Entitlements without a group ID (should not happen for auto-renewables).
        subscriptions += entitlements
            .filter { $0.groupId == nil }
            .map { SubscriptionFacts(transaction: $0, renewalState: nil, willAutoRenew: nil) }
        return subscriptions
    }

    func transactionUpdates() -> AsyncStream<TransactionFacts> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) { [self] in
                for await result in Transaction.updates {
                    continuation.yield(Self.facts(from: payload(result)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func statusUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                for await _ in Product.SubscriptionInfo.Status.updates {
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: StoreKit → facts

    /// Unverified transactions are still reported (we only observe; the backend verifies through
    /// store server notifications), but logged.
    private func payload<T>(_ result: VerificationResult<T>) -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified(let value, let error):
            logger.info("StoreKit returned an unverified payload (\(error)); reporting it anyway")
            return value
        }
    }

    private func facts(from status: Product.SubscriptionInfo.Status, groupId: String) -> SubscriptionFacts {
        var transaction = Self.facts(from: payload(status.transaction))
        if transaction.groupId == nil { transaction.groupId = groupId }
        let renewalInfo = payload(status.renewalInfo)
        return SubscriptionFacts(
            transaction: transaction,
            renewalState: Self.renewalState(status.state),
            willAutoRenew: renewalInfo.willAutoRenew
        )
    }

    static func facts(from transaction: Transaction) -> TransactionFacts {
        TransactionFacts(
            transactionId: String(transaction.id),
            originalTransactionId: String(transaction.originalID),
            productId: transaction.productID,
            groupId: transaction.subscriptionGroupID,
            purchaseDate: transaction.purchaseDate,
            expiresAt: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            offerType: offerType(of: transaction),
            isFreeTrial: isFreeTrial(transaction),
            environment: environment(of: transaction),
            reason: reason(of: transaction),
            isAutoRenewable: transaction.productType == .autoRenewable,
            isUpgraded: transaction.isUpgraded,
            accountToken: transaction.appAccountToken?.uuidString.lowercased()
        )
    }

    static func renewalState(_ state: Product.SubscriptionInfo.RenewalState) -> RenewalStateValue? {
        switch state {
        case .subscribed: return .subscribed
        case .expired: return .expired
        case .inBillingRetryPeriod: return .inBillingRetryPeriod
        case .inGracePeriod: return .inGracePeriod
        case .revoked: return .revoked
        default: return nil
        }
    }

    private static func offerType(of transaction: Transaction) -> OfferTypeValue? {
        let type: Transaction.OfferType?
        if #available(iOS 17.2, macOS 14.2, *) {
            type = transaction.offer?.type
        } else {
            type = transaction.offerType
        }
        switch type {
        case .introductory?: return .introductory
        case .promotional?: return .promotional
        case .code?: return .offerCode
        case .winBack?: return .winBack
        default: return nil
        }
    }

    private static func isFreeTrial(_ transaction: Transaction) -> Bool {
        if #available(iOS 17.2, macOS 14.2, *) {
            guard let offer = transaction.offer, offer.type == .introductory else { return false }
            return offer.paymentMode == .freeTrial
        } else {
            guard transaction.offerType == .introductory else { return false }
            return SubscriptionMapping.isFreeTrial(paymentMode: transaction.offerPaymentModeStringRepresentation)
        }
    }

    private static func environment(of transaction: Transaction) -> String? {
        switch transaction.environment {
        case .production: return "production"
        case .sandbox: return "sandbox"
        case .xcode: return "xcode"
        default: return SubscriptionMapping.environment(transaction.environment.rawValue)
        }
    }

    private static func reason(of transaction: Transaction) -> TransactionReasonValue? {
        switch transaction.reason {
        case .purchase: return .purchase
        case .renewal: return .renewal
        default: return nil
        }
    }

    // MARK: Timeout

    /// Runs `operation`; returns `nil` if it throws or hasn't finished after `seconds`.
    /// Doesn't wait for a stuck StoreKit call to notice cancellation.
    static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(continuation)
            let work = Task { once.resume(try? await operation()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.resume(nil) { work.cancel() }
            }
        }
    }
}

/// Resumes a continuation exactly once, from whichever side gets there first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

    @discardableResult
    func resume(_ value: T?) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
        return pending != nil
    }
}
