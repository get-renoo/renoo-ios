import XCTest
@testable import Renoo

/// A scripted StoreKit.
final class FakeSubscriptionSource: SubscriptionSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _subscriptions: [SubscriptionFacts] = []
    private(set) var requestedGroups: [Set<String>] = []
    let updates: AsyncStream<TransactionFacts>
    private let continuation: AsyncStream<TransactionFacts>.Continuation

    init() {
        var continuation: AsyncStream<TransactionFacts>.Continuation!
        updates = AsyncStream { continuation = $0 }
        self.continuation = continuation
        var statusContinuation: AsyncStream<Void>.Continuation!
        statusChanges = AsyncStream { statusContinuation = $0 }
        self.statusContinuation = statusContinuation
    }

    var subscriptions: [SubscriptionFacts] {
        get { lock.lock(); defer { lock.unlock() }; return _subscriptions }
        set { lock.lock(); _subscriptions = newValue; lock.unlock() }
    }

    /// Makes every read suspend, like StoreKit does.
    var readDelay: UInt64 = 0

    func subscriptions(knownGroupIds: Set<String>) async -> [SubscriptionFacts] {
        if readDelay > 0 { try? await Task.sleep(nanoseconds: readDelay) }
        return record(knownGroupIds)
    }

    private func record(_ groups: Set<String>) -> [SubscriptionFacts] {
        lock.lock(); defer { lock.unlock() }
        requestedGroups.append(groups)
        return _subscriptions
    }

    func transactionUpdates() -> AsyncStream<TransactionFacts> { updates }

    func emit(_ transaction: TransactionFacts) { continuation.yield(transaction) }

    let statusChanges: AsyncStream<Void>
    private let statusContinuation: AsyncStream<Void>.Continuation

    func statusUpdates() -> AsyncStream<Void> { statusChanges }

    func emitStatusChange() { statusContinuation.yield(()) }
}

final class SubscriptionCollectorTests: XCTestCase {
    private var harness: TestHarness!
    private var source: FakeSubscriptionSource!

    override func setUp() {
        super.setUp()
        harness = TestHarness()
        source = FakeSubscriptionSource()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    private func makeCollector(_ environment: SDKEnvironment) -> SubscriptionCollector {
        SubscriptionCollector(environment: environment, source: source, now: { Fixture.now })
    }

    private func states(_ events: [Event]) -> [String] {
        events.filter { $0.name == .subscriptionState }.compactMap {
            if case .string(let status)? = $0.properties["status"] { return status }
            return nil
        }
    }

    func testSubscriberOpensTheGateAndBufferedEventsAreKept() async {
        let environment = harness.makeEnvironment()
        environment.pipeline.track(.appOpen, properties: ["start_type": "cold"])
        XCTAssertTrue(environment.storedEvents().withoutIdentify.isEmpty, "buffered until the state is known")

        source.subscriptions = [Fixture.subscription(.subscribed)]
        await makeCollector(environment).tracker.refresh(trigger: .appOpen)

        let events = environment.storedEvents().withoutIdentify
        XCTAssertEqual(events.map(\.name), [.appOpen, .subscriptionState])
        XCTAssertEqual(events[1].properties["status"], "active")
        XCTAssertEqual(events[1].properties["trigger"], "app_open")
        XCTAssertEqual(events[1].properties["auto_renew"], true)
    }

    func testNonSubscriberIsNotTracked() async {
        let environment = harness.makeEnvironment()
        environment.pipeline.track(.appOpen)
        await makeCollector(environment).tracker.refresh(trigger: .appOpen)
        environment.pipeline.track(.screenView)
        XCTAssertTrue(environment.storedEvents().withoutIdentify.isEmpty)
    }

    func testGraceAndBillingRetryAreTracked() async {
        for state in [RenewalStateValue.inGracePeriod, .inBillingRetryPeriod] {
            let harness = TestHarness()
            defer { harness.tearDown() }
            let environment = harness.makeEnvironment()
            source.subscriptions = [Fixture.subscription(state)]
            await makeCollector(environment).tracker.refresh(trigger: .appOpen)
            environment.pipeline.track(.screenView)
            XCTAssertEqual(environment.storedEvents().withoutIdentify.map(\.name), [.subscriptionState, .screenView], "\(state)")
        }
    }

    func testExpiryIsRecordedThenTheGateCloses() async {
        let environment = harness.makeEnvironment()
        let collector = makeCollector(environment)
        source.subscriptions = [Fixture.subscription(.subscribed)]
        await collector.tracker.refresh(trigger: .appOpen)

        // The expired subscription has left current entitlements and the status API shows nothing.
        source.subscriptions = []
        await collector.tracker.refresh(trigger: .appOpen)
        environment.pipeline.track(.screenView)

        let events = environment.storedEvents().withoutIdentify
        XCTAssertEqual(states(events), ["active", "expired"])
        XCTAssertEqual(events.last?.properties["auto_renew"], false)
        XCTAssertEqual(events.last?.properties["product_id"], "com.test.monthly")
        XCTAssertFalse(events.contains { $0.name == .screenView }, "dropped once the user lapsed")
    }

    func testRememberedStateSurvivesRelaunchAndGroupsAreRequested() async {
        let first = harness.makeEnvironment()
        source.subscriptions = [Fixture.subscription(.subscribed)]
        await makeCollector(first).tracker.refresh(trigger: .appOpen)

        let relaunched = TestHarness(defaultsSuite: harness.suiteName)
        let environment = relaunched.makeEnvironment(scope: .everyone)
        source.subscriptions = []
        await makeCollector(environment).tracker.refresh(trigger: .appOpen)
        XCTAssertEqual(states(environment.storedEvents().withoutIdentify).last, "expired")
        XCTAssertEqual(source.requestedGroups.last, ["g1"])
        try? FileManager.default.removeItem(at: relaunched.directory)
    }

    func testNewPurchaseEmitsTransactionThenStateAndOpensTheGate() async {
        let environment = harness.makeEnvironment()
        let collector = makeCollector(environment)
        await collector.tracker.refresh(trigger: .appOpen) // not a subscriber yet: gate closed

        let purchase = Fixture.transaction(id: "1", original: "1", offer: .introductory, freeTrial: true, reason: .purchase)
        source.subscriptions = [Fixture.subscription(.subscribed, purchase)]
        await collector.tracker.handle(purchase)

        let events = environment.storedEvents().withoutIdentify
        XCTAssertEqual(events.map(\.name), [.transaction, .subscriptionState])
        XCTAssertEqual(events[0].properties["kind"], "purchase")
        XCTAssertEqual(events[0].properties["offer_type"], "introductory")
        XCTAssertEqual(events[1].properties["status"], "trial")
        XCTAssertEqual(events[1].properties["is_trial"], true)
        XCTAssertEqual(events[1].properties["trigger"], "transaction_update")
    }

    func testTransactionsAreNotEmittedTwiceAcrossLaunches() async {
        let environment = harness.makeEnvironment(scope: .everyone)
        let renewal = Fixture.transaction(id: "7", reason: .renewal)
        source.subscriptions = [Fixture.subscription(.subscribed, renewal)]
        await makeCollector(environment).tracker.handle(renewal)
        await makeCollector(environment).tracker.handle(renewal)
        await makeCollector(environment).tracker.refresh(trigger: .appOpen)

        let transactions = environment.storedEvents().withoutIdentify.filter { $0.name == .transaction }
        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transactions.first?.properties["kind"], "renewal")

        // A refund of the same transaction is a new event.
        let refunded = Fixture.transaction(id: "7", revoked: true)
        source.subscriptions = [Fixture.subscription(.revoked, refunded)]
        await makeCollector(environment).tracker.handle(refunded)
        let kinds = environment.storedEvents().withoutIdentify.filter { $0.name == .transaction }.map { $0.properties["kind"] }
        XCTAssertEqual(kinds, ["renewal", "revocation"])
    }

    func testReusedTestEnvironmentIdIsANewTransaction() async {
        // Xcode StoreKit testing: clearing transactions restarts IDs, so a new purchase is "0" again.
        let environment = harness.makeEnvironment(scope: .everyone)
        let collector = makeCollector(environment)
        let first = Fixture.transaction(id: "0", original: "0", reason: .purchase)
        source.subscriptions = [Fixture.subscription(.subscribed, first)]
        await collector.tracker.handle(first)

        var second = Fixture.transaction(id: "0", original: "0", product: "com.test.annual", reason: .purchase)
        second.purchaseDate = first.purchaseDate.addingTimeInterval(120)
        source.subscriptions = [Fixture.subscription(.subscribed, second)]
        await collector.tracker.handle(second)
        await collector.tracker.handle(second)

        let products = environment.storedEvents().withoutIdentify.filter { $0.name == .transaction }.map { $0.properties["product_id"] }
        XCTAssertEqual(products, ["com.test.monthly", "com.test.annual"])
    }

    func testFirstReadSeedsHistoryThenCatchesMissedRenewals() async {
        let environment = harness.makeEnvironment(scope: .everyone)
        let collector = makeCollector(environment)
        source.subscriptions = [Fixture.subscription(.subscribed, Fixture.transaction(id: "1", original: "1"))]
        await collector.tracker.refresh(trigger: .appOpen)
        XCTAssertFalse(environment.storedEvents().withoutIdentify.contains { $0.name == .transaction }, "existing history is not re-emitted")

        // A renewal that happened while the app was closed and never came through updates.
        source.subscriptions = [Fixture.subscription(.subscribed, Fixture.transaction(id: "2", original: "1"))]
        await collector.tracker.refresh(trigger: .appOpen)
        let events = environment.storedEvents().withoutIdentify
        XCTAssertEqual(events.map(\.name), [.subscriptionState, .transaction, .subscriptionState])
        XCTAssertEqual(events[1].properties["kind"], "renewal")
    }

    func testUpgradeIsDetectedFromProductHistory() async {
        let environment = harness.makeEnvironment(scope: .everyone)
        let collector = makeCollector(environment)
        source.subscriptions = [Fixture.subscription(.subscribed, Fixture.transaction(id: "1", original: "1", product: "monthly"))]
        await collector.tracker.refresh(trigger: .appOpen)

        let upgrade = Fixture.transaction(id: "2", original: "1", product: "annual", reason: .purchase)
        source.subscriptions = [Fixture.subscription(.subscribed, upgrade)]
        await collector.tracker.handle(upgrade)
        let transaction = environment.storedEvents().withoutIdentify.first { $0.name == .transaction }
        XCTAssertEqual(transaction?.properties["kind"], "upgrade")
    }

    func testIgnoresNonSubscriptionAndSupersededTransactions() async {
        let environment = harness.makeEnvironment(scope: .everyone)
        let collector = makeCollector(environment)
        await collector.tracker.handle(Fixture.transaction(id: "c", autoRenewable: false))
        await collector.tracker.handle(Fixture.transaction(id: "u", upgraded: true))
        XCTAssertTrue(environment.storedEvents().withoutIdentify.isEmpty)
    }

    func testStartReadsStateAndListensForUpdates() async throws {
        let environment = harness.makeEnvironment()
        let collector = makeCollector(environment)
        collector.start()
        let defaults = harness.defaults
        try await waitFor { defaults.bool(forKey: SubscriptionTracker.Keys.seeded) } // first read done
        XCTAssertTrue(environment.storedEvents().withoutIdentify.isEmpty, "not a subscriber: nothing stored")

        let purchase = Fixture.transaction(id: "1", original: "1", reason: .purchase)
        source.subscriptions = [Fixture.subscription(.subscribed, purchase)]
        source.emit(purchase)
        try await waitFor { self.states(environment.storedEvents().withoutIdentify) == ["active"] }
        XCTAssertEqual(environment.storedEvents().withoutIdentify.map(\.name), [.transaction, .subscriptionState])
    }

    func testInAppPurchaseIsReportedFromAStatusChange() async throws {
        // `Product.purchase()` in the app: StoreKit returns the transaction to the caller and never
        // puts it on `Transaction.updates`; only the subscription status stream reports it.
        let environment = harness.makeEnvironment()
        let collector = makeCollector(environment)
        collector.start()
        let defaults = harness.defaults
        try await waitFor { defaults.bool(forKey: SubscriptionTracker.Keys.seeded) }

        let purchase = Fixture.transaction(id: "1", original: "1", reason: .purchase)
        source.subscriptions = [Fixture.subscription(.subscribed, purchase)]
        source.emitStatusChange()
        source.emitStatusChange() // StoreKit often reports one change twice
        try await waitFor { self.states(environment.storedEvents().withoutIdentify) == ["active"] }
        let events = environment.storedEvents().withoutIdentify
        XCTAssertEqual(events.map(\.name), [.transaction, .subscriptionState])
        XCTAssertEqual(events[0].properties["kind"], "purchase")
        XCTAssertEqual(events[1].properties["trigger"], "transaction_update")

        // Auto-renew turned off: no transaction, a changed state.
        source.subscriptions = [Fixture.subscription(.subscribed, autoRenew: false, purchase)]
        source.emitStatusChange()
        try await waitFor { self.states(environment.storedEvents().withoutIdentify).count == 2 }
        XCTAssertEqual(environment.storedEvents().withoutIdentify.last?.properties["auto_renew"], false)
        XCTAssertEqual(environment.storedEvents().withoutIdentify.last?.properties["trigger"], "status_update")
        XCTAssertEqual(environment.storedEvents().withoutIdentify.filter { $0.name == .transaction }.count, 1)
    }

    func testStatusChangeAndTransactionUpdateTogetherEmitOneTransactionThenOneState() async {
        // A new purchase arrives on both streams at once; reads suspend while StoreKit answers.
        let environment = harness.makeEnvironment(scope: .everyone)
        let collector = makeCollector(environment)
        await collector.tracker.refresh(trigger: .appOpen) // none; seeds history
        source.readDelay = 50_000_000
        let purchase = Fixture.transaction(id: "1", original: "1", reason: .purchase)
        source.subscriptions = [Fixture.subscription(.subscribed, purchase)]

        async let update: Void = collector.tracker.handle(purchase)
        async let status: Void = collector.tracker.statusChanged()
        async let status2: Void = collector.tracker.statusChanged()
        _ = await (update, status, status2)

        let names = environment.storedEvents().withoutIdentify.map(\.name)
        XCTAssertEqual(names, [.subscriptionState, .transaction, .subscriptionState], "\(names)")
        XCTAssertEqual(states(environment.storedEvents().withoutIdentify), ["none", "active"])
    }

    func testStatusChangeWithoutChangeEmitsNothing() async {
        let environment = harness.makeEnvironment(scope: .everyone)
        let collector = makeCollector(environment)
        source.subscriptions = [Fixture.subscription(.subscribed)]
        await collector.tracker.refresh(trigger: .appOpen)
        await collector.tracker.statusChanged()
        XCTAssertEqual(states(environment.storedEvents().withoutIdentify), ["active"])
    }

    func testColdLaunchForegroundNotificationDoesNotEmitASecondAppOpenState() async {
        // A scene-based app posts willEnterForeground during a cold launch, right after start().
        let clock = Clock(Fixture.now)
        let environment = harness.makeEnvironment()
        let collector = SubscriptionCollector(environment: environment, source: source, now: { clock.now })
        source.subscriptions = [Fixture.subscription(.subscribed)]

        async let launch: Void = collector.tracker.appOpened()
        async let foreground: Void = collector.tracker.appOpened()
        _ = await (launch, foreground)
        clock.advance(0.2)
        await collector.tracker.appOpened()
        XCTAssertEqual(states(environment.storedEvents().withoutIdentify), ["active"], "one subscription_state per app open")

        // A real return to the foreground later is read again.
        clock.advance(SubscriptionTracker.appOpenCoalescingInterval)
        await collector.tracker.appOpened()
        XCTAssertEqual(states(environment.storedEvents().withoutIdentify), ["active", "active"])
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met in \(timeout) s")
    }
}

/// A settable clock for the collector's `now`.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
}

private extension Array where Element == Event {
    /// The `identify` sent when the gate opens is covered by AnonymousIdTests.
    var withoutIdentify: [Event] { filter { $0.name != .identify } }
}
