import Foundation

// Plain values that describe what StoreKit reported, and the pure rules that turn them into
// `subscription_state` and `transaction` events. No StoreKit here, so it is unit-tested on macOS.

/// `subscription_state.status` in the event schema.
enum SubscriptionStatus: String, CaseIterable, Sendable {
    case active, trial
    case gracePeriod = "grace_period"
    case billingRetry = "billing_retry"
    case expired, revoked, none

    /// In tracking scope (an active paid subscription or trial): still has access or is about to be recovered.
    var isTracked: Bool {
        switch self {
        case .active, .trial, .gracePeriod, .billingRetry: return true
        case .expired, .revoked, .none: return false
        }
    }

    /// Lower is better. Picks the subscription to report when the user has several.
    fileprivate var rank: Int {
        switch self {
        case .active: return 0
        case .trial: return 1
        case .gracePeriod: return 2
        case .billingRetry: return 3
        case .expired: return 4
        case .revoked: return 5
        case .none: return 6
        }
    }
}

/// `Product.SubscriptionInfo.RenewalState`.
enum RenewalStateValue: String, Codable, Sendable {
    case subscribed, expired, inBillingRetryPeriod, inGracePeriod, revoked
}

/// `Transaction.OfferType`, as written in events.
enum OfferTypeValue: String, Codable, Sendable {
    case introductory, promotional
    case offerCode = "offer_code"
    case winBack = "win_back"
}

/// `Transaction.reason`. `nil` for a reason this SDK version doesn't know.
enum TransactionReasonValue: String, Codable, Sendable {
    case purchase, renewal
}

/// `transaction.kind` in the event schema.
enum TransactionKind: String, Sendable {
    case purchase, renewal, upgrade, revocation
}

enum SubscriptionTrigger: String, Sendable {
    case appOpen = "app_open"
    case transactionUpdate = "transaction_update"
    /// A StoreKit status update that brought no new transaction (auto-renew off, expiry).
    case statusUpdate = "status_update"
}

/// One StoreKit transaction, reduced to what the events need.
struct TransactionFacts: Codable, Equatable, Sendable {
    var transactionId: String
    var originalTransactionId: String
    var productId: String
    var groupId: String?
    var purchaseDate: Date
    var expiresAt: Date?
    var revocationDate: Date?
    var offerType: OfferTypeValue?
    /// The transaction is an introductory free trial.
    var isFreeTrial: Bool
    /// `production`, `sandbox` or `xcode`.
    var environment: String?
    var reason: TransactionReasonValue?
    var isAutoRenewable: Bool
    /// This transaction was replaced by an upgrade (the new one arrives separately).
    var isUpgraded: Bool
    /// `Transaction.appAccountToken`, lowercase. `nil` when the client set none.
    var accountToken: String? = nil

    /// Transaction ID plus purchase time (ms). StoreKit's local test environment (Xcode StoreKit
    /// configuration, `SKTestSession`) restarts IDs at 0 whenever its transactions are cleared, so
    /// the ID alone would hide new purchases behind old ones. A refund arrives as the same
    /// transaction with a revocation date, so it gets its own key.
    var dedupeKey: String {
        let key = "\(transactionId)@\(Int64((purchaseDate.timeIntervalSince1970 * 1000).rounded()))"
        return revocationDate == nil ? key : "\(key):revoked"
    }
}

/// One subscription as StoreKit sees it: its latest transaction plus renewal status.
/// `renewalState` and `willAutoRenew` are `nil` when only the transaction is known
/// (the status API failed or timed out).
struct SubscriptionFacts: Codable, Equatable, Sendable {
    var transaction: TransactionFacts
    var renewalState: RenewalStateValue?
    var willAutoRenew: Bool?
}

enum SubscriptionMapping {
    // MARK: Status

    static func status(of facts: SubscriptionFacts, now: Date) -> SubscriptionStatus {
        let transaction = facts.transaction
        if transaction.revocationDate != nil || facts.renewalState == .revoked { return .revoked }
        switch facts.renewalState {
        case .inGracePeriod: return .gracePeriod
        case .inBillingRetryPeriod: return .billingRetry
        case .expired: return .expired
        case .subscribed: return transaction.isFreeTrial ? .trial : .active
        case .revoked: return .revoked
        case nil:
            if let expiresAt = transaction.expiresAt, expiresAt <= now { return .expired }
            return transaction.isFreeTrial ? .trial : .active
        }
    }

    /// The subscription to report when there are several (several groups, or family sharing):
    /// the best status, then the latest expiry.
    static func primary(_ candidates: [SubscriptionFacts], now: Date) -> SubscriptionFacts? {
        candidates.min { a, b in
            let rankA = status(of: a, now: now).rank
            let rankB = status(of: b, now: now).rank
            if rankA != rankB { return rankA < rankB }
            return (a.transaction.expiresAt ?? .distantPast) > (b.transaction.expiresAt ?? .distantPast)
        }
    }

    /// The state to report. When StoreKit shows nothing but we saw a subscription before, the
    /// user is reported as `expired` (or `revoked`) with the remembered details: expired
    /// subscriptions can drop out of `Transaction.currentEntitlements`.
    static func resolve(
        current: [SubscriptionFacts],
        remembered: SubscriptionFacts?,
        now: Date
    ) -> (status: SubscriptionStatus, facts: SubscriptionFacts?) {
        if let primary = primary(current, now: now) {
            return (status(of: primary, now: now), primary)
        }
        guard var remembered else { return (.none, nil) }
        remembered.willAutoRenew = false
        let wasRevoked = remembered.transaction.revocationDate != nil || remembered.renewalState == .revoked
        remembered.renewalState = wasRevoked ? .revoked : .expired
        return (wasRevoked ? .revoked : .expired, remembered)
    }

    static func stateProperties(
        status: SubscriptionStatus,
        facts: SubscriptionFacts?,
        trigger: SubscriptionTrigger
    ) -> [String: JSONValue] {
        let transaction = status == .none ? nil : facts?.transaction
        return [
            "status": .string(status.rawValue),
            "product_id": .optional(transaction?.productId),
            "auto_renew": transaction == nil ? .null : .optional(facts?.willAutoRenew),
            "expires_at": .timestamp(transaction?.expiresAt),
            "original_transaction_id": .optional(transaction?.originalTransactionId),
            "transaction_id": .optional(transaction?.transactionId),
            "is_trial": .optional(transaction?.isFreeTrial),
            "offer_type": .optional(transaction?.offerType?.rawValue),
            "environment": .optional(transaction?.environment),
            "account_token": .optional(transaction?.accountToken),
            // StoreKit has no purchase token and infers nothing: always null and [] on iOS.
            "purchase_token": .null,
            "inferred_fields": .array([]),
            // How the Android SDK estimated trial / expiry. StoreKit reports facts, so always
            // null on iOS; written explicitly because the schema wants null, not a missing key.
            "inference_basis": .null,
            "trigger": .string(trigger.rawValue),
        ]
    }

    // MARK: Transactions

    /// - Parameter previousProductId: the product last seen for the same original transaction ID.
    static func kind(of transaction: TransactionFacts, previousProductId: String?) -> TransactionKind {
        if transaction.revocationDate != nil { return .revocation }
        if transaction.reason == .renewal { return .renewal }
        if transaction.transactionId == transaction.originalTransactionId { return .purchase }
        if let previousProductId, previousProductId != transaction.productId { return .upgrade }
        // Same product, later transaction in the chain: a resubscribe (reason `purchase`) or,
        // for a reason this SDK version doesn't know, most likely a renewal.
        return transaction.reason == .purchase ? .purchase : .renewal
    }

    static func transactionProperties(_ transaction: TransactionFacts, kind: TransactionKind) -> [String: JSONValue] {
        [
            "product_id": .string(transaction.productId),
            "transaction_id": .string(transaction.transactionId),
            "original_transaction_id": .string(transaction.originalTransactionId),
            "purchase_date": .timestamp(transaction.purchaseDate),
            "kind": .string(kind.rawValue),
            "offer_type": .optional(transaction.offerType?.rawValue),
            "environment": .optional(transaction.environment),
            "purchase_token": .null,
            "account_token": .optional(transaction.accountToken),
        ]
    }

    // MARK: Raw StoreKit strings

    /// Payment mode strings (`FREE_TRIAL` from the pre-17.2 string API, `freeTrial` style
    /// spellings tolerated) → is it a free trial.
    static func isFreeTrial(paymentMode: String?) -> Bool {
        guard let paymentMode else { return false }
        return paymentMode.replacingOccurrences(of: "_", with: "").lowercased() == "freetrial"
    }

    /// StoreKit's raw environment value (`Production` / `Sandbox` / `Xcode` or a future one) → lowercase.
    static func environment(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.lowercased()
    }
}
