#if os(iOS) && canImport(StoreKitTest)
import StoreKit
import StoreKitTest
import XCTest
@testable import Renoo

/// End to end against StoreKit's local test environment (`StoreKit/TestProducts.storekit`).
/// iOS Simulator only: `xcodebuild test ... -destination 'platform=iOS Simulator,...'`.
/// The test drives the store with `SKTestSession`; the SDK itself only observes.
final class StoreKitSessionTests: XCTestCase {
    private static let monthly = "dev.renoo.test.monthly"
    private static let annual = "dev.renoo.test.annual"

    private var session: SKTestSession!
    private var harness: TestHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The simulator can read the Mac's file system, so the config is loaded from the repo.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StoreKit/TestProducts.storekit")
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        harness = TestHarness()
    }

    override func tearDown() {
        session?.clearTransactions()
        harness?.tearDown()
        super.tearDown()
    }

    func testConfigurationProducts() async throws {
        let products = try await Product.products(for: [Self.monthly, Self.annual])
        let monthly = try XCTUnwrap(products.first { $0.id == Self.monthly })
        let annual = try XCTUnwrap(products.first { $0.id == Self.annual })

        XCTAssertEqual(monthly.price, Decimal(string: "9.99"))
        assertPeriod(monthly.subscription?.subscriptionPeriod, 1, .month)
        let intro = try XCTUnwrap(monthly.subscription?.introductoryOffer)
        XCTAssertEqual(intro.paymentMode, .freeTrial)
        assertPeriod(intro.period, 1, .week)
        let promo = try XCTUnwrap(monthly.subscription?.promotionalOffers.first)
        XCTAssertEqual(promo.id, "monthly_50_off")
        XCTAssertEqual(promo.paymentMode, .payAsYouGo)
        XCTAssertEqual(promo.price, Decimal(string: "4.99"))
        assertPeriod(promo.period, 1, .month)
        XCTAssertEqual(promo.periodCount, 1)

        XCTAssertEqual(annual.price, Decimal(string: "59.99"))
        assertPeriod(annual.subscription?.subscriptionPeriod, 1, .year)
        XCTAssertNil(annual.subscription?.introductoryOffer)
        XCTAssertEqual(monthly.subscription?.subscriptionGroupID, annual.subscription?.subscriptionGroupID)
    }

    func testBuyDisableAutoRenewAndExpire() async throws {
        let environment = harness.makeEnvironment()
        let collector = SubscriptionCollector(environment: environment)
        collector.start()
        let defaults = harness.defaults
        try await waitFor("first read") { defaults.bool(forKey: SubscriptionTracker.Keys.seeded) }
        XCTAssertTrue(environment.storedEvents().isEmpty, "no subscription yet: not tracked")

        // Buy: Transaction.updates delivers it; the collector emits `transaction` + `subscription_state`.
        do {
            try await session.buyProduct(identifier: Self.monthly)
        } catch {
            // In a package test bundle (no host app) the buy succeeds but returning the signed
            // transaction fails ("didn't return the expected transaction JWS"). The store state is
            // updated either way, which is all the collector observes.
            print("SKTestSession.buyProduct: \(error)")
        }
        let testTransaction = try XCTUnwrap(session.allTransactions().last)
        // Without a host app, StoreKit in the test process never sees the purchase: no
        // `Transaction.updates`, empty `currentEntitlements`, empty status. Skip rather than fake it.
        guard await Self.hasEntitlement(Self.monthly) else {
            throw XCTSkip("""
                StoreKit can't see SKTestSession purchases in a package test bundle without a host app \
                (\"Missing transaction data for purchase\"). The hosted version runs in the local test app, which is not in this repo.
                """)
        }
        try await waitFor("purchase via Transaction.updates") {
            self.lastState(environment)?["trigger"] == "transaction_update"
        }
        let events = environment.storedEvents()
        let transaction = try XCTUnwrap(events.first { $0.name == .transaction })
        XCTAssertEqual(transaction.properties["kind"], "purchase")
        XCTAssertEqual(transaction.properties["product_id"], .string(Self.monthly))
        XCTAssertEqual(transaction.properties["transaction_id"], .string(String(testTransaction.identifier)))
        XCTAssertEqual(transaction.properties["offer_type"], "introductory")
        XCTAssertEqual(transaction.properties["environment"], "xcode")
        var state = try XCTUnwrap(lastState(environment))
        XCTAssertEqual(state["status"], "trial")
        XCTAssertEqual(state["is_trial"], true)
        XCTAssertEqual(state["auto_renew"], true)
        XCTAssertEqual(state["original_transaction_id"], .string(String(testTransaction.originalTransactionIdentifier)))
        XCTAssertNotEqual(state["expires_at"], JSONValue.null)

        // Turn off auto-renew, then the app comes back to the foreground.
        try session.disableAutoRenewForTransaction(identifier: testTransaction.identifier)
        await collector.tracker.refresh(trigger: .appOpen)
        state = try XCTUnwrap(lastState(environment))
        XCTAssertEqual(state["auto_renew"], false)
        XCTAssertEqual(state["trigger"], "app_open")
        XCTAssertEqual(state["status"], "trial")

        // Expire it.
        try session.expireSubscription(productIdentifier: Self.monthly)
        await collector.tracker.refresh(trigger: .appOpen)
        state = try XCTUnwrap(lastState(environment))
        XCTAssertEqual(state["status"], "expired")
        XCTAssertEqual(state["product_id"], .string(Self.monthly))

        // The gate is closed now: later events are dropped.
        let count = environment.storedEvents().count
        environment.pipeline.track(.screenView)
        XCTAssertEqual(environment.storedEvents().count, count)

        let transactions = environment.storedEvents().filter { $0.name == .transaction }
        XCTAssertEqual(transactions.count, 1, "the purchase is reported once")
    }

    // MARK: Helpers

    private static func hasEntitlement(_ productId: String, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result, transaction.productID == productId { return true }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline
        return false
    }

    private func assertPeriod(
        _ period: Product.SubscriptionPeriod?, _ value: Int, _ unit: Product.SubscriptionPeriod.Unit,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(period?.value, value, file: file, line: line)
        XCTAssertEqual(period?.unit, unit, file: file, line: line)
    }

    private func lastState(_ environment: SDKEnvironment) -> [String: JSONValue]? {
        environment.storedEvents().last { $0.name == .subscriptionState }?.properties
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 15, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("timed out waiting for \(what)")
        throw XCTSkip("stopping after timeout")
    }
}
#endif
