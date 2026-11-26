import XCTest
@testable import Renoo

final class LifecycleEngineTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var nextId = 0

    override func setUp() {
        super.setUp()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        nextId = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A new engine on the same defaults = a new process.
    private func launch(timeout: TimeInterval = LifecycleEngine.sessionTimeout) -> LifecycleEngine {
        LifecycleEngine(
            defaults: defaults,
            sessionTimeout: timeout,
            clock: { [unowned self] in now },
            makeSessionId: { [unowned self] in nextId += 1; return "s\(nextId)" },
            context: { ["device_model": "test"] }
        )
    }

    private func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

    private func names(_ steps: [LifecycleStep]) -> [String] {
        steps.map {
            switch $0 {
            case .setSession(let id): return "set:\(id ?? "nil")"
            case .emit(let name, _, _, _): return name.rawValue
            }
        }
    }

    private func emitted(_ name: EventName, in steps: [LifecycleStep]) -> (properties: [String: JSONValue], timestamp: Date, sessionId: String??)? {
        for step in steps {
            if case let .emit(n, properties, timestamp, sessionId) = step, n == name {
                return (properties, timestamp, sessionId)
            }
        }
        return nil
    }

    // MARK: Cold start

    func testFirstColdStartOpensSessionWithContextAndNoForeground() throws {
        let engine = launch()
        let steps = engine.didBecomeActive()
        XCTAssertEqual(names(steps), ["set:s1", "session_start", "app_open"])
        let start = try XCTUnwrap(emitted(.sessionStart, in: steps))
        XCTAssertEqual(start.properties["context"], ["device_model": "test"])
        XCTAssertEqual(emitted(.appOpen, in: steps)?.properties["start_type"], "cold")
    }

    func testBackgroundBeforeFirstActivationIsIgnored() {
        // Prewarmed or background-launched process: no activation yet, so nothing to report.
        let engine = launch()
        XCTAssertTrue(engine.didEnterBackground().isEmpty)
        XCTAssertEqual(names(engine.didBecomeActive()), ["set:s1", "session_start", "app_open"])
    }

    func testRepeatedActivationWithoutBackgroundIsNotANewOpen() {
        let engine = launch()
        _ = engine.didBecomeActive()
        advance(5)  // e.g. Control Centre pulled down and dismissed
        XCTAssertTrue(engine.didBecomeActive().isEmpty)
    }

    // MARK: Warm returns and the timeout

    func testResumeWithinTimeoutContinuesSession() {
        let engine = launch()
        _ = engine.didBecomeActive()
        advance(10)
        XCTAssertEqual(names(engine.didEnterBackground()), ["app_background"])
        advance(20)
        let steps = engine.didBecomeActive()
        XCTAssertEqual(names(steps), ["set:s1", "app_open"])
        XCTAssertEqual(emitted(.appOpen, in: steps)?.properties["start_type"], "warm")
    }

    func testExactlyTimeoutContinuesSession() {
        let engine = launch()
        _ = engine.didBecomeActive()
        _ = engine.didEnterBackground()
        advance(30)
        XCTAssertEqual(names(engine.didBecomeActive()), ["set:s1", "app_open"])
    }

    func testJustOverTimeoutEndsSessionAtBackgroundTime() throws {
        let engine = launch()
        let startedAt = now
        _ = engine.didBecomeActive()
        advance(42.5)
        let backgroundedAt = now
        _ = engine.didEnterBackground()
        advance(30.001)
        let steps = engine.didBecomeActive()
        XCTAssertEqual(names(steps), ["session_end", "set:s2", "session_start", "app_open"])

        let end = try XCTUnwrap(emitted(.sessionEnd, in: steps))
        XCTAssertEqual(end.timestamp, backgroundedAt)
        XCTAssertEqual(end.sessionId, .some("s1"))
        XCTAssertEqual(end.properties["reason"], "timeout")
        XCTAssertEqual(end.properties["duration_ms"], .int(Int(backgroundedAt.timeIntervalSince(startedAt) * 1000)))
        XCTAssertEqual(end.properties["duration_ms"], 42_500)
        // New-session events use the pipeline's current session (set just before).
        XCTAssertEqual(emitted(.sessionStart, in: steps)?.sessionId, .none)
    }

    func testCustomTimeout() {
        let engine = launch(timeout: 300)
        _ = engine.didBecomeActive()
        _ = engine.didEnterBackground()
        advance(299)
        XCTAssertFalse(names(engine.didBecomeActive()).contains("session_end"))
        _ = engine.didEnterBackground()
        advance(301)
        XCTAssertTrue(names(engine.didBecomeActive()).contains("session_end"))
    }

    // MARK: Cold start after a clean background

    func testColdStartAfterBackgroundBeyondTimeoutEndsOldSession() throws {
        let first = launch()
        _ = first.didBecomeActive()
        advance(60)
        let backgroundedAt = now
        _ = first.didEnterBackground()
        advance(3_600)  // process killed while suspended; reopened an hour later

        let second = launch()
        let steps = second.didBecomeActive()
        XCTAssertEqual(names(steps), ["session_end", "set:s2", "session_start", "app_open"])
        let end = try XCTUnwrap(emitted(.sessionEnd, in: steps))
        XCTAssertEqual(end.timestamp, backgroundedAt)
        XCTAssertEqual(end.sessionId, .some("s1"))
        XCTAssertEqual(end.properties["duration_ms"], 60_000)
        XCTAssertEqual(emitted(.appOpen, in: steps)?.properties["start_type"], "cold")
        XCTAssertNil(emitted(.uncleanExit, in: steps))
    }

    func testColdStartWithinTimeoutContinuesSession() {
        let first = launch()
        _ = first.didBecomeActive()
        _ = first.didEnterBackground()
        advance(10)  // swiped away and relaunched quickly

        let steps = launch().didBecomeActive()
        XCTAssertEqual(names(steps), ["set:s1", "app_open"])
        XCTAssertEqual(emitted(.appOpen, in: steps)?.properties["start_type"], "cold")
    }

    // MARK: Unclean exit

    func testColdStartAfterForegroundCrashReportsUncleanExit() throws {
        let first = launch()
        let startedAt = now
        _ = first.didBecomeActive()
        advance(45)
        first.recordActivity()  // heartbeat
        let lastActive = now
        advance(20)  // crashes here, with no background event
        advance(600)

        let second = launch()
        let relaunchAt = now
        let steps = second.didBecomeActive()
        XCTAssertEqual(names(steps), ["unclean_exit", "session_end", "set:s2", "session_start", "app_open"])

        let unclean = try XCTUnwrap(emitted(.uncleanExit, in: steps))
        XCTAssertEqual(unclean.properties["previous_session_id"], "s1")
        XCTAssertEqual(unclean.properties["last_active_at"], .timestamp(lastActive))
        XCTAssertEqual(unclean.timestamp, relaunchAt)
        XCTAssertEqual(unclean.sessionId, .some(nil))

        let end = try XCTUnwrap(emitted(.sessionEnd, in: steps))
        XCTAssertEqual(end.properties["reason"], "unclean_exit")
        XCTAssertEqual(end.timestamp, lastActive)
        XCTAssertEqual(end.sessionId, .some("s1"))
        XCTAssertEqual(end.properties["duration_ms"], .int(Int(lastActive.timeIntervalSince(startedAt) * 1000)))
    }

    func testCrashRightAfterWarmReturnIsUnclean() {
        let first = launch()
        _ = first.didBecomeActive()
        _ = first.didEnterBackground()
        advance(5)
        _ = first.didBecomeActive()
        advance(5)  // crash
        XCTAssertEqual(names(launch().didBecomeActive()).first, "unclean_exit")
    }

    func testNoUncleanExitAfterCleanBackgroundOrOnFirstRun() {
        XCTAssertFalse(names(launch().didBecomeActive()).contains("unclean_exit"))
        let engine = launch()  // previous run never went to the background → unclean
        XCTAssertTrue(names(engine.didBecomeActive()).contains("unclean_exit"))
        _ = engine.didEnterBackground()
        advance(1)
        XCTAssertFalse(names(launch().didBecomeActive()).contains("unclean_exit"))
    }

    func testUncleanExitIsReportedOnlyOnce() {
        _ = launch().didBecomeActive()
        let second = launch()
        XCTAssertTrue(names(second.didBecomeActive()).contains("unclean_exit"))
        _ = second.didEnterBackground()
        let third = launch()
        XCTAssertFalse(names(third.didBecomeActive()).contains("unclean_exit"))
    }

    // MARK: Robustness

    func testClockGoingBackwardsNeverProducesNegativeDuration() throws {
        let engine = launch()
        _ = engine.didBecomeActive()
        advance(-100)
        _ = engine.didEnterBackground()
        advance(1_000)
        let end = try XCTUnwrap(emitted(.sessionEnd, in: engine.didBecomeActive()))
        XCTAssertEqual(end.properties["duration_ms"], 0)
    }

    func testCorruptPersistedStateStartsFresh() {
        defaults.set(Data("not json".utf8), forKey: LifecycleEngine.stateKey)
        XCTAssertEqual(names(launch().didBecomeActive()), ["set:s1", "session_start", "app_open"])
    }
}
