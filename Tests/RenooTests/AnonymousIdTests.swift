import XCTest
@testable import Renoo

/// The anonymous ID (decided 2026-11-26): generated at configure, kept in the SDK's
/// UserDefaults, on every event, and announced with one `identify` per anonymous ID.
final class AnonymousIdTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        Renoo._setCoreForTesting(nil)
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A pipeline over this test's UserDefaults and queue directory. Calling it again simulates
    /// an app restart: memory is gone, disk and UserDefaults are kept.
    private func launch(scope: Configuration.TrackingScope = .subscribersOnly) -> EventPipeline {
        let logger = SDKLogger(level: .none)
        let directory = directory!
        return EventPipeline(
            queue: DispatchQueue(label: "test"),
            storeProvider: { EventStore(directory: directory, logger: logger) },
            defaults: defaults,
            logger: logger,
            envelope: .init(sdkVersion: "0.0.0", appVersion: "1.0", appBuild: "1", osVersion: "26.0.0"),
            trackingScope: scope,
            installIdProvider: { "install-1" }
        )
    }

    private func identifies(_ pipeline: EventPipeline) -> [Event] {
        pipeline.queuedEvents().filter { $0.name == .identify }
    }

    // MARK: Generation and persistence

    func testGeneratedAtConfigureAsLowercaseUUIDAndPersisted() throws {
        let pipeline = launch()
        let id = pipeline.anonymousId
        let uuid = try XCTUnwrap(UUID(uuidString: id), "a UUID")
        XCTAssertEqual(id, uuid.uuidString.lowercased(), "lowercase")
        XCTAssertEqual(id, id.lowercased())
        XCTAssertEqual(id.count, 36)
        XCTAssertEqual(Array(id)[14], "4", "version 4")
        XCTAssertEqual(defaults.string(forKey: EventPipeline.anonymousIdKey), id, "stored in UserDefaults")
    }

    func testSurvivesARestart() {
        let id = launch().anonymousId
        XCTAssertEqual(launch().anonymousId, id)
    }

    func testANewInstallGetsANewId() {
        let id = launch().anonymousId
        defaults.removePersistentDomain(forName: suiteName)  // what an uninstall does
        XCTAssertNotEqual(launch().anonymousId, id)
    }

    func testPublicAccessorIsNilBeforeConfigureAndSetAfter() {
        Renoo._setCoreForTesting(nil)
        XCTAssertNil(Renoo.anonymousId)
        let core = SDKCore(
            configuration: Configuration(apiKey: "test", purchaseHandler: { _ in .cancelled }),
            defaults: defaults,
            storeDirectory: directory
        )
        Renoo._setCoreForTesting(core)
        XCTAssertEqual(Renoo.anonymousId, defaults.string(forKey: EventPipeline.anonymousIdKey))
        XCTAssertNotNil(Renoo.anonymousId)
    }

    // MARK: Envelope

    func testPresentOnEveryEventIncludingBufferedOnes() {
        let pipeline = launch()
        pipeline.track(.appOpen)          // buffered: the gate is not open yet
        pipeline.track(.screenView)
        pipeline.setTrackingState(.tracked, scope: .subscribersOnly)
        pipeline.track(.appBackground)
        let events = pipeline.queuedEvents()
        XCTAssertEqual(events.map(\.name), [.appOpen, .screenView, .identify, .appBackground])
        XCTAssertEqual(Set(events.map(\.anonymousId)), [pipeline.anonymousId])
        XCTAssertTrue(events.allSatisfy { $0.installId == "install-1" && $0.userId == nil })
    }

    func testEncodedAsAnonymousIdNeverNull() throws {
        let pipeline = launch(scope: .everyone)
        pipeline.track(.appOpen)
        let event = try XCTUnwrap(pipeline.queuedEvents().first)
        let json = event.jsonObject()
        XCTAssertEqual(json["anonymous_id"] as? String, pipeline.anonymousId)
        XCTAssertTrue(json["user_id"] is NSNull)
        let decoded = try JSONDecoder().decode(Event.self, from: event.jsonData())
        XCTAssertEqual(decoded, event)
    }

    // MARK: Identity sent once tracked

    func testIdentifyEmittedOnceWhenTheGateOpens() {
        let pipeline = launch()
        pipeline.track(.appOpen)
        XCTAssertTrue(pipeline.queuedEvents().isEmpty, "nothing before the gate opens")
        pipeline.setTrackingState(.tracked, scope: .subscribersOnly)
        pipeline.setTrackingState(.unknown, scope: .subscribersOnly)
        pipeline.setTrackingState(.tracked, scope: .subscribersOnly)
        let sent = identifies(pipeline)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.properties, ["user_id": .null])
        XCTAssertNil(sent.first?.userId)
        XCTAssertEqual(defaults.string(forKey: EventPipeline.identitySentKey), pipeline.anonymousId)
    }

    func testIdentifyNotResentAfterARestart() {
        let first = launch()
        first.setTrackingState(.tracked, scope: .subscribersOnly)
        XCTAssertEqual(identifies(first).count, 1)

        let second = launch()
        second.setTrackingState(.tracked, scope: .subscribersOnly)
        second.track(.appOpen)
        XCTAssertEqual(identifies(second).count, 1, "still only the one from the first launch")
        XCTAssertEqual(second.queuedEvents().last?.name, .appOpen)
    }

    func testEveryoneScopeSendsIdentityAtStart() {
        let pipeline = launch(scope: .everyone)
        pipeline.start()
        pipeline.start()
        XCTAssertEqual(identifies(pipeline).count, 1)
        XCTAssertEqual(identifies(launch(scope: .everyone)).count, 1)
    }

    func testTheGateHoldsNonSubscribers() {
        let pipeline = launch()
        pipeline.start()
        pipeline.track(.appOpen)
        pipeline.identify(userId: "user-1")
        pipeline.reset()
        pipeline.setTrackingState(.notTracked, scope: .subscribersOnly)
        pipeline.track(.screenView)
        pipeline.identify(userId: "user-2")
        XCTAssertTrue(pipeline.queuedEvents().isEmpty, "nothing stored for a non-subscriber")
        XCTAssertNil(defaults.string(forKey: EventPipeline.identitySentKey))
    }

    // MARK: identify(userId)

    func testIdentifyWithUserId() {
        let pipeline = launch(scope: .everyone)
        pipeline.identify(userId: "user-1")
        pipeline.identify(userId: "user-1")
        pipeline.track(.appOpen)
        let events = pipeline.queuedEvents()
        XCTAssertEqual(events.map(\.name), [.identify, .appOpen], "no duplicate for the same user ID")
        XCTAssertEqual(events[0].properties, ["user_id": .string("user-1")])
        XCTAssertEqual(events.map(\.userId), ["user-1", "user-1"])
        XCTAssertEqual(Set(events.map(\.anonymousId)), [pipeline.anonymousId])

        // The identify with the user ID counts as the one per anonymous ID.
        pipeline.start()
        XCTAssertEqual(identifies(pipeline).count, 1)

        // A different user ID is a new identify.
        pipeline.identify(userId: "user-2")
        XCTAssertEqual(identifies(pipeline).map(\.userId), ["user-1", "user-2"])

        // After a restart the stored user ID is still current: no duplicate.
        launch(scope: .everyone).identify(userId: "user-2")
        XCTAssertEqual(identifies(launch(scope: .everyone)).count, 2)
    }

    func testIdentifyBeforeTheGateOpensIsNotDuplicated() {
        let pipeline = launch()
        pipeline.identify(userId: "user-1")
        pipeline.setTrackingState(.tracked, scope: .subscribersOnly)
        let sent = identifies(pipeline)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.userId, "user-1")
    }

    // MARK: reset()

    func testResetGivesANewIdAndReemitsIdentify() {
        let pipeline = launch(scope: .everyone)
        pipeline.identify(userId: "user-1")
        pipeline.track(.appOpen)
        let oldId = pipeline.anonymousId

        pipeline.reset()
        pipeline.track(.screenView)
        pipeline.waitUntilIdle()
        let newId = pipeline.anonymousId
        XCTAssertNotEqual(newId, oldId)
        XCTAssertEqual(newId, newId.lowercased())
        XCTAssertEqual(defaults.string(forKey: EventPipeline.anonymousIdKey), newId)
        XCTAssertNil(defaults.string(forKey: "user_id"))

        let events = pipeline.queuedEvents()
        XCTAssertEqual(events.map(\.name), [.identify, .appOpen, .identify, .screenView])
        XCTAssertEqual(events.map(\.anonymousId), [oldId, oldId, newId, newId], "captured events keep the old ID")
        XCTAssertEqual(events.map(\.userId), ["user-1", "user-1", nil, nil])
        XCTAssertEqual(events[2].properties, ["user_id": .null])

        // The new ID survives a restart and its identify is not sent again.
        let restarted = launch(scope: .everyone)
        restarted.start()
        XCTAssertEqual(restarted.anonymousId, newId)
        XCTAssertEqual(identifies(restarted).count, 2)

        // Logging in again identifies the new anonymous ID with the user.
        restarted.identify(userId: "user-1")
        XCTAssertEqual(identifies(restarted).last?.anonymousId, newId)
        XCTAssertEqual(identifies(restarted).last?.userId, "user-1")
    }

    func testResetBeforeTheGateOpensSendsIdentityForTheNewIdOnly() {
        let pipeline = launch()
        pipeline.track(.appOpen)
        let oldId = pipeline.anonymousId
        pipeline.reset()
        pipeline.setTrackingState(.tracked, scope: .subscribersOnly)
        let events = pipeline.queuedEvents()
        XCTAssertEqual(events.map(\.name), [.appOpen, .identify])
        XCTAssertEqual(events[0].anonymousId, oldId, "buffered before the reset")
        XCTAssertEqual(events[1].anonymousId, pipeline.anonymousId)
        XCTAssertNotEqual(oldId, pipeline.anonymousId)
    }

    // MARK: Opt-out

    func testOptOutKeepsTheIdAndOptInResendsIdentity() {
        let pipeline = launch(scope: .everyone)
        pipeline.start()
        let id = pipeline.anonymousId
        pipeline.setOptedOut(true)
        pipeline.waitUntilIdle()
        XCTAssertEqual(pipeline.anonymousId, id)
        XCTAssertTrue(pipeline.queuedEvents().isEmpty)

        pipeline.setOptedOut(false)
        let events = pipeline.queuedEvents()
        XCTAssertEqual(events.map(\.name), [.identify], "the cleared identify goes out again")
        XCTAssertEqual(events.first?.anonymousId, id)
    }
}
