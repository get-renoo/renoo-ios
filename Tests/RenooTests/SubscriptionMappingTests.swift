import XCTest
@testable import Renoo

/// Builders shared by the subscription tests.
enum Fixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func transaction(
        id: String = "2",
        original: String = "1",
        product: String = "com.test.monthly",
        group: String? = "g1",
        expiresIn: TimeInterval? = 86_400,
        revoked: Bool = false,
        offer: OfferTypeValue? = nil,
        freeTrial: Bool = false,
        reason: TransactionReasonValue? = nil,
        autoRenewable: Bool = true,
        upgraded: Bool = false
    ) -> TransactionFacts {
        TransactionFacts(
            transactionId: id,
            originalTransactionId: original,
            productId: product,
            groupId: group,
            purchaseDate: now.addingTimeInterval(-3_600),
            expiresAt: expiresIn.map { now.addingTimeInterval($0) },
            revocationDate: revoked ? now : nil,
            offerType: offer,
            isFreeTrial: freeTrial,
            environment: "xcode",
            reason: reason,
            isAutoRenewable: autoRenewable,
            isUpgraded: upgraded
        )
    }

    static func subscription(
        _ state: RenewalStateValue?,
        autoRenew: Bool? = true,
        _ transaction: TransactionFacts = transaction()
    ) -> SubscriptionFacts {
        SubscriptionFacts(transaction: transaction, renewalState: state, willAutoRenew: autoRenew)
    }
}

final class SubscriptionMappingTests: XCTestCase {
    private let now = Fixture.now

    func testStatusFromRenewalState() {
        let cases: [(SubscriptionFacts, SubscriptionStatus)] = [
            (Fixture.subscription(.subscribed), .active),
            (Fixture.subscription(.subscribed, Fixture.transaction(offer: .introductory, freeTrial: true)), .trial),
            (Fixture.subscription(.inGracePeriod), .gracePeriod),
            (Fixture.subscription(.inBillingRetryPeriod), .billingRetry),
            (Fixture.subscription(.expired), .expired),
            (Fixture.subscription(.revoked), .revoked),
            (Fixture.subscription(.subscribed, Fixture.transaction(revoked: true)), .revoked),
            // No status API answer: decide from the transaction alone.
            (Fixture.subscription(nil, autoRenew: nil), .active),
            (Fixture.subscription(nil, autoRenew: nil, Fixture.transaction(freeTrial: true)), .trial),
            (Fixture.subscription(nil, autoRenew: nil, Fixture.transaction(expiresIn: -1)), .expired),
        ]
        for (facts, expected) in cases {
            XCTAssertEqual(SubscriptionMapping.status(of: facts, now: now), expected, "\(facts)")
        }
    }

    func testTrackedStatuses() {
        let tracked = SubscriptionStatus.allCases.filter(\.isTracked)
        XCTAssertEqual(tracked, [.active, .trial, .gracePeriod, .billingRetry])
    }

    func testPrimaryPrefersBestStatusThenLatestExpiry() {
        let expired = Fixture.subscription(.expired, Fixture.transaction(id: "e", expiresIn: 999_999))
        let retry = Fixture.subscription(.inBillingRetryPeriod, Fixture.transaction(id: "r"))
        let activeSoon = Fixture.subscription(.subscribed, Fixture.transaction(id: "a1", expiresIn: 10))
        let activeLater = Fixture.subscription(.subscribed, Fixture.transaction(id: "a2", expiresIn: 100))
        XCTAssertEqual(SubscriptionMapping.primary([expired, retry], now: now)?.transaction.transactionId, "r")
        XCTAssertEqual(
            SubscriptionMapping.primary([expired, activeSoon, retry, activeLater], now: now)?.transaction.transactionId,
            "a2"
        )
        XCTAssertNil(SubscriptionMapping.primary([], now: now))
    }

    func testResolveRemembersExpiredSubscriptions() {
        XCTAssertEqual(SubscriptionMapping.resolve(current: [], remembered: nil, now: now).status, .none)

        let remembered = Fixture.subscription(.subscribed, autoRenew: true)
        let (status, facts) = SubscriptionMapping.resolve(current: [], remembered: remembered, now: now)
        XCTAssertEqual(status, .expired)
        XCTAssertEqual(facts?.willAutoRenew, false)
        XCTAssertEqual(facts?.transaction.productId, "com.test.monthly")

        let revoked = Fixture.subscription(.revoked)
        XCTAssertEqual(SubscriptionMapping.resolve(current: [], remembered: revoked, now: now).status, .revoked)

        let current = Fixture.subscription(.subscribed)
        XCTAssertEqual(SubscriptionMapping.resolve(current: [current], remembered: remembered, now: now).status, .active)
    }

    func testStatePropertiesMatchTheSchema() {
        let facts = Fixture.subscription(.subscribed, autoRenew: false, Fixture.transaction(offer: .introductory, freeTrial: true))
        let properties = SubscriptionMapping.stateProperties(status: .trial, facts: facts, trigger: .appOpen)
        XCTAssertEqual(properties, [
            "status": "trial",
            "product_id": "com.test.monthly",
            "auto_renew": false,
            "expires_at": "2027-01-16T08:00:00.000Z",
            "original_transaction_id": "1",
            "transaction_id": "2",
            "is_trial": true,
            "offer_type": "introductory",
            "environment": "xcode",
            "account_token": .null,
            "purchase_token": .null,
            "inferred_fields": .array([]),
            "inference_basis": .null,
            "trigger": "app_open",
        ])
    }

    func testNoneHasEveryFieldNull() {
        let properties = SubscriptionMapping.stateProperties(status: .none, facts: nil, trigger: .transactionUpdate)
        XCTAssertEqual(properties.count, 14)
        XCTAssertEqual(properties["status"], "none")
        XCTAssertEqual(properties["trigger"], "transaction_update")
        for key in ["product_id", "auto_renew", "expires_at", "original_transaction_id", "transaction_id",
                    "is_trial", "offer_type", "environment", "inference_basis", "purchase_token", "account_token"] {
            XCTAssertEqual(properties[key], JSONValue.null, key)
        }
        XCTAssertEqual(properties["inferred_fields"], .array([]))
    }

    func testNullAndEmptyFieldsAreWrittenNotLeftOut() throws {
        let facts = Fixture.subscription(.subscribed, autoRenew: true, Fixture.transaction())
        let event = Event(
            eventId: "e", name: .subscriptionState, timestamp: "2026-11-16T00:00:00.000Z", seq: 1, installId: "i", anonymousId: "a",
            userId: nil, sessionId: nil, schemaVersion: 1, sdkVersion: "0", platform: "ios",
            appVersion: "1", appBuild: "1", osVersion: "26",
            properties: SubscriptionMapping.stateProperties(status: .active, facts: facts, trigger: .appOpen)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(event.jsonString().utf8)) as? [String: Any])
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        XCTAssertTrue(properties["inference_basis"] is NSNull)
        XCTAssertTrue(properties["purchase_token"] is NSNull)
        XCTAssertTrue(properties["account_token"] is NSNull)
        XCTAssertEqual((properties["inferred_fields"] as? [Any])?.count, 0)
    }

    func testTransactionKind() {
        typealias M = SubscriptionMapping
        XCTAssertEqual(M.kind(of: Fixture.transaction(id: "1", original: "1"), previousProductId: nil), .purchase)
        XCTAssertEqual(M.kind(of: Fixture.transaction(id: "5", reason: .renewal), previousProductId: nil), .renewal)
        XCTAssertEqual(M.kind(of: Fixture.transaction(id: "5", revoked: true), previousProductId: nil), .revocation)
        XCTAssertEqual(
            M.kind(of: Fixture.transaction(id: "5", product: "annual", reason: .purchase), previousProductId: "monthly"),
            .upgrade
        )
        // Unknown reason: same product later in the chain is a renewal.
        XCTAssertEqual(M.kind(of: Fixture.transaction(id: "5"), previousProductId: "com.test.monthly"), .renewal)
        // Resubscribing to the same product after it lapsed.
        XCTAssertEqual(M.kind(of: Fixture.transaction(id: "5", reason: .purchase), previousProductId: "com.test.monthly"), .purchase)
    }

    func testTransactionProperties() {
        let properties = SubscriptionMapping.transactionProperties(Fixture.transaction(offer: .promotional), kind: .renewal)
        XCTAssertEqual(properties, [
            "product_id": "com.test.monthly",
            "transaction_id": "2",
            "original_transaction_id": "1",
            "purchase_date": "2027-01-15T07:00:00.000Z",
            "kind": "renewal",
            "offer_type": "promotional",
            "environment": "xcode",
            "purchase_token": .null,
            "account_token": .null,
        ])
    }

    func testAccountTokenIsCarriedOnTransactionAndState() {
        var transaction = Fixture.transaction()
        transaction.accountToken = "6f1c2c1e-3b0a-4c39-9a51-2f0c8d8e7a10"
        XCTAssertEqual(
            SubscriptionMapping.transactionProperties(transaction, kind: .purchase)["account_token"],
            "6f1c2c1e-3b0a-4c39-9a51-2f0c8d8e7a10"
        )
        let facts = Fixture.subscription(.subscribed, transaction)
        XCTAssertEqual(
            SubscriptionMapping.stateProperties(status: .active, facts: facts, trigger: .statusUpdate)["account_token"],
            "6f1c2c1e-3b0a-4c39-9a51-2f0c8d8e7a10"
        )
    }

    func testDedupeKeySeparatesRevocations() {
        XCTAssertEqual(Fixture.transaction(id: "9").dedupeKey, "9@1799996400000")
        XCTAssertEqual(Fixture.transaction(id: "9", revoked: true).dedupeKey, "9@1799996400000:revoked")
    }

    func testDedupeKeySeparatesReusedTestEnvironmentIds() {
        // Clearing Xcode / SKTestSession transactions restarts IDs at 0: a later purchase reuses "0".
        var first = Fixture.transaction(id: "0", original: "0")
        var later = first
        later.purchaseDate = first.purchaseDate.addingTimeInterval(60)
        XCTAssertNotEqual(first.dedupeKey, later.dedupeKey)
        first.purchaseDate = later.purchaseDate
        XCTAssertEqual(first.dedupeKey, later.dedupeKey, "the same transaction read twice keeps its key")
    }

    func testRawStoreKitStrings() {
        XCTAssertTrue(SubscriptionMapping.isFreeTrial(paymentMode: "FREE_TRIAL"))
        XCTAssertTrue(SubscriptionMapping.isFreeTrial(paymentMode: "freeTrial"))
        XCTAssertFalse(SubscriptionMapping.isFreeTrial(paymentMode: "PAY_AS_YOU_GO"))
        XCTAssertFalse(SubscriptionMapping.isFreeTrial(paymentMode: nil))
        XCTAssertEqual(SubscriptionMapping.environment("Sandbox"), "sandbox")
        XCTAssertEqual(SubscriptionMapping.environment("Xcode"), "xcode")
        XCTAssertNil(SubscriptionMapping.environment(""))
    }
}
