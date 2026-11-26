import XCTest
@testable import Renoo

/// The collector wired to a real pipeline: events land on disk with the right envelope.
final class LifecycleCollectorTests: XCTestCase {
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

    private func makeCore() -> SDKCore {
        var configuration = Configuration(apiKey: "pk_test", purchaseHandler: { _ in .cancelled })
        configuration.trackingScope = .everyone
        configuration.logLevel = .none
        configuration.automaticScreenTracking = false
        return SDKCore(configuration: configuration, defaults: defaults, storeDirectory: directory)
    }

    func testColdOpenStampsSessionAndCarriesContext() throws {
        let core = makeCore()
        core.lifecycle.becameActive()
        core.screens.trackScreen(name: "Home", source: .manual)
        core.lifecycle.waitUntilIdle()
        core.lifecycle.enteredBackground()
        core.lifecycle.waitUntilIdle()

        let events = core.environment.pipeline.queuedEvents()
        XCTAssertEqual(events.map(\.name), [.sessionStart, .appOpen, .screenView, .appBackground])
        let session = try XCTUnwrap(events[0].sessionId)
        XCTAssertTrue(events.allSatisfy { $0.sessionId == session })

        guard case .object(let context)? = events[0].properties["context"] else {
            return XCTFail("session_start has no context object")
        }
        for key in ["device_model", "locale", "timezone", "network_type", "low_power_mode",
                    "dark_mode", "push_permission", "days_since_install", "is_reinstall"] {
            XCTAssertNotNil(context[key], key)
        }
    }

    func testUncleanExitAcrossProcesses() {
        let first = makeCore()
        first.lifecycle.becameActive()
        first.lifecycle.waitUntilIdle()
        let firstSession = first.environment.pipeline.queuedEvents().first?.sessionId

        // Simulated crash: a new core on the same disk and defaults, no background in between.
        let second = makeCore()
        second.lifecycle.becameActive()
        second.lifecycle.waitUntilIdle()
        let events = second.environment.pipeline.queuedEvents().dropFirst(2)
        XCTAssertEqual(events.map(\.name), [.uncleanExit, .sessionEnd, .sessionStart, .appOpen])
        let unclean = events.first!
        XCTAssertNil(unclean.sessionId)
        XCTAssertEqual(unclean.properties["previous_session_id"], .optional(firstSession))
        XCTAssertEqual(Array(events)[1].sessionId, firstSession)
        XCTAssertEqual(Array(events)[1].properties["reason"], "unclean_exit")
        XCTAssertNotEqual(Array(events)[2].sessionId, firstSession)
    }
}
