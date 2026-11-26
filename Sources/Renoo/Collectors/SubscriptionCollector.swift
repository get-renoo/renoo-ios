import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Subscription state through StoreKit 2, and the tracking gate: only users with an active paid
/// subscription or trial are tracked.
///
/// - At start and on every return to the foreground: reads the state, emits `subscription_state`
///   (trigger `app_open`) and opens or closes the tracking gate. A scene-based app also posts
///   `willEnterForegroundNotification` during a cold launch, so that read is coalesced with the
///   launch read (one `subscription_state` per app open).
/// - For the whole process lifetime: listens to `Transaction.updates`; each new transaction emits
///   `transaction` and a fresh `subscription_state` (trigger `transaction_update`).
/// - Also listens to subscription status changes. That is the only signal for a
///   purchase the app itself makes with `Product.purchase()` (StoreKit returns it to the caller and
///   never puts it on `Transaction.updates`) and for auto-renew changes. Each change re-reads the
///   state; new transactions are emitted as above, and `subscription_state` (trigger
///   `transaction_update`) only if it differs from the last one emitted.
///
/// Observe only: never calls `finish()` or `purchase()`. StoreKit work runs in an actor off the
/// main thread; `start()` returns immediately.
final class SubscriptionCollector: Collector {
    let tracker: SubscriptionTracker
    private let source: SubscriptionSource
    private var updatesTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?

    convenience init(environment: SDKEnvironment) {
        self.init(environment: environment, source: StoreKitSubscriptionSource(logger: environment.logger))
    }

    init(environment: SDKEnvironment, source: SubscriptionSource, now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.tracker = SubscriptionTracker(environment: environment, source: source, now: now)
    }

    deinit {
        updatesTask?.cancel()
        statusTask?.cancel()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    func start() {
        let tracker = tracker
        let updates = source.transactionUpdates()
        updatesTask = Task.detached(priority: .utility) {
            for await transaction in updates {
                await tracker.handle(transaction)
            }
        }
        let statusUpdates = source.statusUpdates()
        statusTask = Task.detached(priority: .utility) {
            for await _ in statusUpdates {
                await tracker.statusChanged()
            }
        }
        // The pipeline buffers every event until this first read finishes.
        Task.detached(priority: .userInitiated) {
            await tracker.appOpened()
        }
        #if canImport(UIKit)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task.detached(priority: .utility) { await tracker.appOpened() }
        }
        #endif
    }
}

/// Serialises every state read and transaction so events come out in a sensible order.
actor SubscriptionTracker {
    enum Keys {
        /// JSON `SubscriptionFacts` of the last subscription seen, to report `expired` later.
        static let lastSubscription = "subscription.last"
        static let groupIds = "subscription.group_ids"
        /// Dedupe keys of transactions already emitted (most recent last).
        static let seenTransactions = "subscription.seen_transactions"
        /// Set after the first read, which records existing transactions without emitting them.
        static let seeded = "subscription.seeded"
        /// original transaction ID → last product ID, to tell upgrades from renewals.
        static let productHistory = "subscription.product_history"
    }

    static let maxSeenTransactions = 300
    static let maxProductHistory = 50
    /// An app-open read this soon after the previous one (or while it is still running) is skipped.
    static let appOpenCoalescingInterval: TimeInterval = 2

    private let environment: SDKEnvironment
    private let source: SubscriptionSource
    private let now: @Sendable () -> Date
    private var defaults: UserDefaults { environment.defaults }
    private var appOpenReadInFlight = false
    private var lastAppOpenRead: Date?
    /// Properties of the last `subscription_state` emitted, without `trigger`.
    private var lastState: [String: JSONValue]?

    init(environment: SDKEnvironment, source: SubscriptionSource, now: @escaping @Sendable () -> Date) {
        self.environment = environment
        self.source = source
        self.now = now
    }

    /// A transaction from `Transaction.updates`.
    func handle(_ transaction: TransactionFacts) async {
        guard transaction.isAutoRenewable, !transaction.isUpgraded else { return }
        await serialized {
            var seen = await self.seenTransactions()
            guard !seen.contains(transaction.dedupeKey) else {
                self.environment.logger.debug("transaction \(transaction.dedupeKey) already reported")
                return
            }
            seen.append(transaction.dedupeKey)
            await self.saveSeen(seen)
            await self.read(trigger: .transactionUpdate, newTransactions: [transaction])
        }
    }

    /// The app was launched or came back to the foreground: reads and emits the state (trigger
    /// `app_open`) unless another app-open read is running or started less than
    /// `appOpenCoalescingInterval` ago. A cold launch in a scene-based app reaches here twice.
    func appOpened() async {
        let date = now()
        if appOpenReadInFlight {
            environment.logger.debug("app-open subscription read already running; skipped")
            return
        }
        if let last = lastAppOpenRead, date >= last, date.timeIntervalSince(last) < Self.appOpenCoalescingInterval {
            environment.logger.debug("app-open subscription read done \(date.timeIntervalSince(last)) s ago; skipped")
            return
        }
        appOpenReadInFlight = true
        lastAppOpenRead = date
        await refresh(trigger: .appOpen)
        appOpenReadInFlight = false
    }

    /// StoreKit reported a subscription status change. Emits new transactions, and the state only
    /// if it changed (StoreKit often reports one change twice, and alongside `Transaction.updates`).
    func statusChanged() async {
        await serialized { await self.read(trigger: .statusUpdate, newTransactions: [], onlyIfChanged: true) }
    }

    /// Reads the current state and emits it.
    func refresh(trigger: SubscriptionTrigger) async {
        await serialized { await self.read(trigger: trigger, newTransactions: []) }
    }

    // MARK: Private

    private var lastWork: Task<Void, Never>?

    /// Runs `work` after every earlier read has finished. The actor alone isn't enough: a read
    /// suspends while StoreKit answers, and a status change and its `Transaction.updates` entry
    /// arrive together, so interleaved reads would emit a state before its transaction, twice.
    private func serialized(_ work: @escaping @Sendable () async -> Void) async {
        let previous = lastWork
        let task = Task {
            await previous?.value
            await work()
        }
        lastWork = task
        await task.value
    }

    private func read(
        trigger: SubscriptionTrigger,
        newTransactions: [TransactionFacts],
        onlyIfChanged: Bool = false
    ) async {
        let current = await source.subscriptions(knownGroupIds: knownGroupIds())
        let date = now()
        rememberGroups(current.compactMap(\.transaction.groupId))

        var transactions = newTransactions
        var seen = seenTransactions()
        let candidates = current.map(\.transaction).filter { !$0.isUpgraded }
        if defaults.bool(forKey: Keys.seeded) {
            // Catch transactions that happened while the app wasn't running and that
            // `Transaction.updates` didn't deliver (for example renewals already finished elsewhere).
            for transaction in candidates where !seen.contains(transaction.dedupeKey) {
                seen.append(transaction.dedupeKey)
                transactions.append(transaction)
            }
        } else {
            // First read for this install: existing transactions are history, not new events.
            seen.append(contentsOf: candidates.map(\.dedupeKey).filter { !seen.contains($0) })
            defaults.set(true, forKey: Keys.seeded)
        }
        saveSeen(seen)

        let (status, facts) = SubscriptionMapping.resolve(current: current, remembered: remembered(), now: date)
        // A status update that turned up a new transaction is reported as a transaction update.
        let trigger: SubscriptionTrigger = trigger == .statusUpdate && !transactions.isEmpty ? .transactionUpdate : trigger
        publish(status: status, facts: facts, trigger: trigger, transactions: transactions, onlyIfChanged: onlyIfChanged)

        var history = productHistory()
        for transaction in transactions + current.map(\.transaction) {
            history[transaction.originalTransactionId] = transaction.productId
        }
        saveProductHistory(history)
        if let primary = SubscriptionMapping.primary(current, now: date) { remember(primary) }
    }

    private func publish(
        status: SubscriptionStatus,
        facts: SubscriptionFacts?,
        trigger: SubscriptionTrigger,
        transactions: [TransactionFacts],
        onlyIfChanged: Bool
    ) {
        var properties = SubscriptionMapping.stateProperties(status: status, facts: facts, trigger: trigger)
        properties["trigger"] = nil
        if onlyIfChanged, transactions.isEmpty, properties == lastState {
            environment.logger.debug("subscription status update: no change")
            return
        }
        lastState = properties
        let pipeline = environment.pipeline
        let scope = environment.configuration.trackingScope
        // Open the gate before a subscriber's events and close it after a lapsed user's last one,
        // so a new purchase and the final `expired` state are both recorded.
        if status.isTracked { pipeline.setTrackingState(.tracked, scope: scope) }
        let history = productHistory()
        for transaction in transactions {
            let kind = SubscriptionMapping.kind(of: transaction, previousProductId: history[transaction.originalTransactionId])
            pipeline.track(.transaction, properties: SubscriptionMapping.transactionProperties(transaction, kind: kind))
        }
        properties["trigger"] = .string(trigger.rawValue)
        pipeline.track(.subscriptionState, properties: properties)
        if !status.isTracked { pipeline.setTrackingState(.notTracked, scope: scope) }
        environment.logger.info("subscription \(status.rawValue) (\(trigger.rawValue))")
    }

    // MARK: Persistence (the SDK's UserDefaults suite)

    private func remembered() -> SubscriptionFacts? {
        guard let data = defaults.data(forKey: Keys.lastSubscription) else { return nil }
        return try? JSONDecoder().decode(SubscriptionFacts.self, from: data)
    }

    private func remember(_ facts: SubscriptionFacts) {
        guard let data = try? JSONEncoder().encode(facts) else { return }
        defaults.set(data, forKey: Keys.lastSubscription)
    }

    private func knownGroupIds() -> Set<String> {
        Set(defaults.stringArray(forKey: Keys.groupIds) ?? [])
    }

    private func rememberGroups(_ groups: [String]) {
        let known = knownGroupIds()
        let all = known.union(groups)
        if all != known { defaults.set(all.sorted(), forKey: Keys.groupIds) }
    }

    private func seenTransactions() -> [String] {
        defaults.stringArray(forKey: Keys.seenTransactions) ?? []
    }

    private func saveSeen(_ seen: [String]) {
        defaults.set(Array(seen.suffix(Self.maxSeenTransactions)), forKey: Keys.seenTransactions)
    }

    private func productHistory() -> [String: String] {
        defaults.dictionary(forKey: Keys.productHistory) as? [String: String] ?? [:]
    }

    private func saveProductHistory(_ history: [String: String]) {
        var trimmed = history
        if trimmed.count > Self.maxProductHistory {
            // Keep it bounded; which entries go doesn't matter much (they're old chains).
            for key in trimmed.keys.sorted().prefix(trimmed.count - Self.maxProductHistory) { trimmed[key] = nil }
        }
        defaults.set(trimmed, forKey: Keys.productHistory)
    }
}
