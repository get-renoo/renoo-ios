import XCTest
@testable import Renoo

final class EventPipelineTests: XCTestCase {
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
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makePipeline(scope: Configuration.TrackingScope = .everyone) -> EventPipeline {
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

    func testEventsArePersistedInOrderWithIncreasingSeq() {
        let pipeline = makePipeline()
        pipeline.setSessionId("s1")
        pipeline.track(.appOpen, properties: ["start_type": "cold"])
        pipeline.track(.screenView, properties: ["screen_name": "Home"])
        let events = pipeline.queuedEvents()
        XCTAssertEqual(events.map(\.name), [.appOpen, .screenView])
        XCTAssertEqual(events.map(\.seq), [1, 2])
        XCTAssertEqual(events.map(\.sessionId), ["s1", "s1"])
        XCTAssertEqual(events[0].installId, "install-1")
        XCTAssertEqual(events[0].platform, "ios")

        // A new pipeline on the same disk and defaults continues the queue and the sequence.
        let second = makePipeline()
        second.track(.appBackground)
        XCTAssertEqual(second.queuedEvents().map(\.seq), [1, 2, 3])
    }

    func testEventsWaitUntilTheUserIsKnownToBeTracked() {
        let pipeline = makePipeline(scope: .subscribersOnly)
        pipeline.track(.appOpen)
        XCTAssertTrue(pipeline.queuedEvents().isEmpty)
        pipeline.setTrackingState(.tracked, scope: .subscribersOnly)
        pipeline.track(.screenView)
        XCTAssertEqual(pipeline.queuedEvents().map(\.name), [.appOpen, .identify, .screenView], "identify goes out when the gate opens")
    }

    func testNothingIsStoredForNonSubscribers() {
        let pipeline = makePipeline(scope: .subscribersOnly)
        pipeline.track(.appOpen)
        pipeline.setTrackingState(.notTracked, scope: .subscribersOnly)
        pipeline.track(.screenView)
        XCTAssertTrue(pipeline.queuedEvents().isEmpty)
    }

    func testSessionOverrideAndPastTimestamp() {
        let pipeline = makePipeline()
        pipeline.setSessionId("current")
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        pipeline.track(.sessionEnd, timestamp: past, sessionId: .some("old"))
        pipeline.track(.appOpen, sessionId: .some(nil))
        let events = pipeline.queuedEvents()
        XCTAssertEqual(events[0].sessionId, "old")
        XCTAssertEqual(events[0].timestamp, "2023-11-14T22:13:20.000Z")
        XCTAssertNil(events[1].sessionId)
    }

    func testIdentifyResetAndOptOut() {
        let pipeline = makePipeline()
        pipeline.setUserId("user-1")
        pipeline.track(.appOpen)
        pipeline.setUserId(nil)
        pipeline.track(.appOpen)
        XCTAssertEqual(pipeline.queuedEvents().map(\.userId), ["user-1", nil])

        pipeline.setOptedOut(true)
        pipeline.track(.appOpen)
        XCTAssertTrue(pipeline.queuedEvents().isEmpty)
        XCTAssertTrue(pipeline.isOptedOut)

        pipeline.setOptedOut(false)
        pipeline.track(.appOpen)
        XCTAssertEqual(pipeline.queuedEvents().map(\.name), [.identify, .appOpen], "identify is sent again after opt-in")
    }

    func testIdentifyAfterOptOutStoresNothing() {
        let pipeline = makePipeline()
        pipeline.setOptedOut(true)
        pipeline.setUserId("user-1")
        pipeline.waitUntilIdle()
        XCTAssertNil(defaults.string(forKey: "user_id"))
        pipeline.setOptedOut(false)
        pipeline.track(.appOpen)
        XCTAssertEqual(pipeline.queuedEvents().map(\.userId), [nil, nil])
        XCTAssertEqual(pipeline.queuedEvents().first?.properties["user_id"], .null)
    }

    func testGettersAreSafeInsideAnObserver() {
        let pipeline = makePipeline()
        var counts: [Int] = []
        var optedOut: [Bool] = []
        _ = pipeline.addObserver { _ in
            counts.append(pipeline.queuedEvents().count)
            optedOut.append(pipeline.isOptedOut)
        }
        pipeline.track(.appOpen)
        pipeline.waitUntilIdle()
        XCTAssertEqual(counts, [1])
        XCTAssertEqual(optedOut, [false])
    }

    func testObserversSeeCommittedEvents() {
        let pipeline = makePipeline()
        var seen: [EventName] = []
        let token = pipeline.addObserver { seen.append($0.name) }
        pipeline.track(.appOpen)
        pipeline.waitUntilIdle()
        pipeline.removeObserver(token)
        pipeline.track(.appBackground)
        pipeline.waitUntilIdle()
        XCTAssertEqual(seen, [.appOpen])
    }

    func testEventJSONUsesSnakeCaseEnvelope() throws {
        let pipeline = makePipeline()
        pipeline.track(.screenView, properties: ["screen_name": "Home", "previous_screen_name": nil])
        let object = try XCTUnwrap(pipeline.queuedEvents().first).jsonObject()
        for key in ["event_id", "name", "timestamp", "seq", "install_id", "schema_version",
                    "sdk_version", "platform", "app_version", "app_build", "os_version", "properties"] {
            XCTAssertNotNil(object[key], key)
        }
        XCTAssertTrue(object["user_id"] is NSNull)
        XCTAssertTrue(object["session_id"] is NSNull)
        XCTAssertEqual(object["name"] as? String, "screen_view")
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        XCTAssertEqual(properties["screen_name"] as? String, "Home")
        XCTAssertTrue(properties["previous_screen_name"] is NSNull)
    }

    func testStoreTrimsOldestEvents() {
        let logger = SDKLogger(level: .none)
        let store = EventStore(directory: directory, maxEvents: 10, logger: logger)
        let pipeline = makePipeline()
        pipeline.track(.appOpen)
        let template = pipeline.queuedEvents()[0]
        store.clear()
        for _ in 0..<25 { store.append(template) }
        XCTAssertLessThanOrEqual(store.count, 10)
        XCTAssertEqual(store.all().count, store.count)
    }
}
