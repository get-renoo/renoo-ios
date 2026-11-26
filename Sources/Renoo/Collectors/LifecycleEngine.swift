import Foundation

/// What the lifecycle engine persists between runs (in the SDK's UserDefaults suite).
struct LifecycleState: Codable, Equatable {
    /// The open session, or nil before the first activation.
    var sessionId: String?
    var sessionStartedAt: Date?
    /// True from an activation until the next move to the background.
    /// Still true on the next cold start means the previous run died in the foreground.
    var inForeground = false
    /// When the app last went to the background. Nil while in the foreground.
    var backgroundedAt: Date?
    /// Best estimate of the last moment the app was alive in the foreground (see `recordActivity`).
    var lastActiveAt: Date?
}

/// One thing the collector must do, in order.
enum LifecycleStep: Equatable {
    /// `pipeline.setSessionId(_:)`.
    case setSession(String?)
    /// `pipeline.track(_:properties:timestamp:sessionId:)`.
    case emit(EventName, properties: [String: JSONValue], timestamp: Date, sessionId: String??)
}

/// The app lifecycle and session rules, without UIKit, so they run under `swift test`.
///
/// Not thread-safe: the collector serialises calls with a lock.
///
/// Order of steps on an activation:
/// `unclean_exit` → old `session_end` → `setSession(new)` → `session_start` → `app_open`.
/// The session ID is switched before `session_start`, so everything from it on is stamped with
/// the new session; the late `session_end` and `unclean_exit` carry explicit overrides.
final class LifecycleEngine {
    static let stateKey = "lifecycle_state"
    /// A session ends when the app spent strictly more than this long in the background.
    /// Fixed: not a client setting.
    static let sessionTimeout: TimeInterval = 30

    private let defaults: UserDefaults
    private let sessionTimeout: TimeInterval
    private let clock: () -> Date
    private let makeSessionId: () -> String
    private let context: () -> [String: JSONValue]

    private(set) var state: LifecycleState
    /// False until the first activation of this process: that one is the cold `app_open`.
    private(set) var hasActivatedThisProcess = false

    init(
        defaults: UserDefaults,
        // Tests only; the SDK always uses the fixed 30 s.
        sessionTimeout: TimeInterval = LifecycleEngine.sessionTimeout,
        clock: @escaping () -> Date = Date.init,
        makeSessionId: @escaping () -> String = { UUID().uuidString.lowercased() },
        context: @escaping () -> [String: JSONValue]
    ) {
        self.defaults = defaults
        self.sessionTimeout = max(0, sessionTimeout)
        self.clock = clock
        self.makeSessionId = makeSessionId
        self.context = context
        if let data = defaults.data(forKey: Self.stateKey),
           let decoded = try? JSONDecoder().decode(LifecycleState.self, from: data) {
            state = decoded
        } else {
            state = LifecycleState()
        }
    }

    /// The session later events should be stamped with, as persisted from the last run.
    /// Not meaningful until the first `didBecomeActive`.
    var currentSessionId: String? { state.sessionId }

    /// The app became active (UIApplication.didBecomeActiveNotification, or already active at `configure`).
    func didBecomeActive() -> [LifecycleStep] {
        let now = clock()
        var steps: [LifecycleStep] = []

        let isCold = !hasActivatedThisProcess
        hasActivatedThisProcess = true

        if !isCold && state.inForeground {
            // Active → inactive → active without a background in between
            // (Control Centre, a system alert, a permission sheet). Not a new open.
            state.lastActiveAt = now
            save()
            return []
        }

        var needsNewSession = state.sessionId == nil

        if isCold, state.inForeground, let previous = state.sessionId {
            // The last run never reached the background: it crashed, was killed by the watchdog
            // or jetsam, or the device died. We only know roughly when it was last alive.
            let lastActive = state.lastActiveAt ?? state.sessionStartedAt ?? now
            steps.append(.emit(
                .uncleanExit,
                properties: [
                    "previous_session_id": .string(previous),
                    "last_active_at": .timestamp(lastActive),
                ],
                timestamp: now,
                sessionId: .some(nil)
            ))
            steps.append(sessionEnd(id: previous, endedAt: lastActive, reason: "unclean_exit"))
            needsNewSession = true
        } else if let previous = state.sessionId, let backgroundedAt = state.backgroundedAt {
            // Returning from the background, in this process (warm) or a new one (cold).
            // "More than the timeout" ends the session; exactly the timeout still continues it.
            if now.timeIntervalSince(backgroundedAt) > sessionTimeout {
                steps.append(sessionEnd(id: previous, endedAt: backgroundedAt, reason: "timeout"))
                needsNewSession = true
            }
        } else if state.sessionId != nil {
            // A session with neither a foreground nor a background mark: corrupt or partial state.
            needsNewSession = true
        }

        if needsNewSession {
            let id = makeSessionId()
            state.sessionId = id
            state.sessionStartedAt = now
            steps.append(.setSession(id))
            steps.append(.emit(.sessionStart, properties: ["context": .object(context())], timestamp: now, sessionId: nil))
        } else {
            steps.append(.setSession(state.sessionId))
        }

        steps.append(.emit(.appOpen, properties: ["start_type": .string(isCold ? "cold" : "warm")], timestamp: now, sessionId: nil))

        state.inForeground = true
        state.backgroundedAt = nil
        state.lastActiveAt = now
        save()
        return steps
    }

    /// The app moved to the background (UIApplication.didEnterBackgroundNotification, or willTerminate).
    func didEnterBackground() -> [LifecycleStep] {
        guard state.inForeground, hasActivatedThisProcess else { return [] }
        let now = clock()
        state.inForeground = false
        state.backgroundedAt = now
        state.lastActiveAt = now
        save()
        return [.emit(.appBackground, properties: [:], timestamp: now, sessionId: nil)]
    }

    /// Marks the app as alive in the foreground right now. Called from a slow heartbeat and on
    /// resign-active; the last value becomes `last_active_at` if this run ends uncleanly.
    func recordActivity() {
        guard state.inForeground, hasActivatedThisProcess else { return }
        state.lastActiveAt = clock()
        save()
    }

    private func sessionEnd(id: String, endedAt: Date, reason: String) -> LifecycleStep {
        let started = state.sessionStartedAt ?? endedAt
        let duration = max(0, Int((endedAt.timeIntervalSince(started) * 1000).rounded()))
        return .emit(
            .sessionEnd,
            properties: ["duration_ms": .int(duration), "reason": .string(reason)],
            timestamp: endedAt,
            sessionId: .some(id)
        )
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.stateKey)
    }
}
