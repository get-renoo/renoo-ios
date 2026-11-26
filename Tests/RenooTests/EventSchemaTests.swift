import Foundation
import XCTest
@testable import Renoo

/// Validates a captured sample of every event type against event schema v1
/// (`event-v1.schema.json`), read from the path in the `RENOO_EVENT_SCHEMA` environment variable.
/// Skipped when the variable isn't set. No network.
final class EventSchemaTests: XCTestCase {
    private var harness: TestHarness!

    override func setUp() {
        super.setUp()
        harness = TestHarness()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    static let schemaEnvironmentKey = "RENOO_EVENT_SCHEMA"

    /// The schema file named by `RENOO_EVENT_SCHEMA`; skips the test when the variable isn't set.
    private func schemaURL() throws -> URL {
        let path = ProcessInfo.processInfo.environment[Self.schemaEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else {
            throw XCTSkip("Set \(Self.schemaEnvironmentKey) to the path of event-v1.schema.json to run this test")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("\(Self.schemaEnvironmentKey) is set but no file exists at \(url.path)")
            throw XCTSkip("schema file missing")
        }
        return url
    }

    private func validator() throws -> JSONSchemaValidator {
        try JSONSchemaValidator(schemaData: Data(contentsOf: schemaURL()))
    }

    // MARK: Tests

    func testEveryEventTypeMatchesSchemaV1() throws {
        let validator = try validator()
        let events = captureOneOfEach()

        let names = Set(events.map(\.name))
        XCTAssertEqual(names, Set(EventName.allCases), "the sample covers every event type")

        for event in events {
            let object = try JSONSerialization.jsonObject(with: event.jsonData())
            let errors = try validator.validate(object)
            XCTAssertEqual(errors, [], "\(event.name.rawValue): \(event.jsonString())")
            XCTAssertEqual(event.schemaVersion, 1)
        }
    }

    /// The validator itself must accept the schema's valid fixtures and reject its invalid ones,
    /// so a broken validator can't pass the test above.
    func testValidatorAgreesWithTheSchemaFixtures() throws {
        let validator = try validator()
        // The schema's fixtures sit next to it, in `fixtures/valid` and `fixtures/invalid`.
        let schemaDirectory = try schemaURL().deletingLastPathComponent()
        for (folder, expectValid) in [("valid", true), ("invalid", false)] {
            let directory = schemaDirectory.appendingPathComponent("fixtures/\(folder)")
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            XCTAssertFalse(files.isEmpty, "no fixtures in \(directory.path)")
            for file in files {
                let errors = try validator.validate(JSONSerialization.jsonObject(with: Data(contentsOf: file)))
                XCTAssertEqual(errors.isEmpty, expectValid, "\(folder)/\(file.lastPathComponent): \(errors)")
            }
        }
    }

    func testUnsupportedKeywordFailsLoudly() {
        let schema = Data(#"{"type": "object", "properties": {"a": {"maxLength": 3}}}"#.utf8)
        XCTAssertThrowsError(try JSONSchemaValidator(schemaData: schema)) { error in
            XCTAssertTrue("\(error)".contains("maxLength"), "\(error)")
        }
    }

    // MARK: Capture

    /// One event of each type, produced by the SDK's own collectors and mapping rules and stored
    /// through the real pipeline, so the envelope is what the SDK sends.
    private func captureOneOfEach() -> [Event] {
        let environment = harness.makeEnvironment(scope: .everyone)
        let pipeline = environment.pipeline

        // install
        InstallCollector(environment: environment).start()

        // session_start (with context), app_open cold and warm, app_background, session_end
        let context = ContextCollector(environment: environment)
        context.refresh()
        environment.queue.sync {}
        var now = Date()
        func apply(_ steps: [LifecycleStep]) {
            for step in steps {
                switch step {
                case .setSession(let id): pipeline.setSessionId(id)
                case let .emit(name, properties, timestamp, sessionId):
                    pipeline.track(name, properties: properties, timestamp: timestamp, sessionId: sessionId)
                }
            }
        }
        let engine = LifecycleEngine(defaults: harness.defaults, clock: { now }, context: { context.snapshot(now: now) })
        apply(engine.didBecomeActive())
        apply(engine.didEnterBackground())
        now += LifecycleEngine.sessionTimeout + 1
        apply(engine.didBecomeActive())

        // unclean_exit: a new process while the last one was still in the foreground
        let relaunch = LifecycleEngine(defaults: harness.defaults, clock: { now }, context: { context.snapshot(now: now) })
        apply(relaunch.didBecomeActive())

        // screen_view
        let screens = ScreenCollector(environment: environment)
        screens.trackScreen(name: "Home", source: .manual)
        screens.trackScreen(name: "Settings", source: .manual)

        // push_permission_changed
        context.pushStatusRead("not_determined")
        context.pushStatusRead("authorized")

        // subscription_state and transaction, with an app account token
        var transaction = Fixture.transaction(id: "1", original: "1", offer: .introductory, freeTrial: true, reason: .purchase)
        transaction.accountToken = UUID().uuidString.lowercased()
        let facts = Fixture.subscription(.subscribed, autoRenew: false, transaction)
        pipeline.track(.transaction, properties: SubscriptionMapping.transactionProperties(transaction, kind: .purchase))
        pipeline.track(.subscriptionState, properties: SubscriptionMapping.stateProperties(status: .trial, facts: facts, trigger: .statusUpdate))
        pipeline.track(.subscriptionState, properties: SubscriptionMapping.stateProperties(status: .none, facts: nil, trigger: .appOpen))

        // identify after login
        pipeline.identify(userId: "user-42")

        return environment.storedEvents()
    }
}
