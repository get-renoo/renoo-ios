import XCTest
@testable import Renoo

final class ContextCollectorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testPushTrackerIsSilentOnFirstReadAndReportsChanges() {
        let tracker = PushPermissionTracker(defaults: defaults)
        XCTAssertNil(tracker.observe("not_determined"))
        XCTAssertNil(tracker.observe("not_determined"))
        let change = tracker.observe("authorized")
        XCTAssertEqual(change?.status, "authorized")
        XCTAssertEqual(change?.previous, "not_determined")
        XCTAssertNil(tracker.observe("authorized"))
        // Survives a new process.
        XCTAssertEqual(PushPermissionTracker(defaults: defaults).observe("denied")?.previous, "authorized")
    }

    func testPushPermissionChangedEvent() {
        var configuration = Configuration(apiKey: "pk_test", purchaseHandler: { _ in .cancelled })
        configuration.trackingScope = .everyone
        configuration.logLevel = .none
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = SDKCore(configuration: configuration, defaults: defaults, storeDirectory: directory)

        core.context.pushStatusRead("denied")
        core.context.pushStatusRead("denied")
        core.context.pushStatusRead("authorized")
        let events = core.environment.pipeline.queuedEvents()
        XCTAssertEqual(events.map(\.name), [.pushPermissionChanged])
        XCTAssertEqual(events.first?.properties, ["status": "authorized", "previous_status": "denied"])
        XCTAssertEqual(core.context.snapshot()["push_permission"], "authorized")
    }

    func testDaysSinceInstall() {
        let installed = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ContextCollector.daysSinceInstall(installDate: installed, now: installed), 0)
        XCTAssertEqual(ContextCollector.daysSinceInstall(installDate: installed, now: installed + 86_399), 0)
        XCTAssertEqual(ContextCollector.daysSinceInstall(installDate: installed, now: installed + 86_400 * 3 + 5), 3)
        XCTAssertEqual(ContextCollector.daysSinceInstall(installDate: installed, now: installed - 500), 0)
    }

    func testLocaleIsBCP47() {
        XCTAssertEqual(ContextCollector.bcp47(Locale(identifier: "en_US")), "en-US")
        XCTAssertEqual(ContextCollector.bcp47(Locale(identifier: "pt_BR")), "pt-BR")
        // The schema checks the shape only: hyphen-separated subtags, no `_` or `@` keywords.
        let shape = try! NSRegularExpression(pattern: "^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$")
        for identifier in ["zh_Hans_CN", "zh-Hans_CN", "en_BR@rg=gbzzzz", "sr_Latn_RS", "de_DE@calendar=buddhist"] {
            let tag = ContextCollector.bcp47(Locale(identifier: identifier)) ?? ""
            XCTAssertNotNil(shape.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)), "\(identifier) → \(tag)")
        }
    }

    func testDeviceModelPrefersSimulatorIdentifier() {
        XCTAssertEqual(ContextCollector.deviceModel(environment: ["SIMULATOR_MODEL_IDENTIFIER": "iPhone18,3"]), "iPhone18,3")
        XCTAssertFalse(ContextCollector.deviceModel(environment: [:]).isEmpty)
    }
}
