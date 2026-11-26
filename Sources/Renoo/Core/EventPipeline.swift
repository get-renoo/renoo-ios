import Foundation

/// Whether the current user is in tracking scope (active subscription or trial).
enum TrackingState: Equatable {
    /// Subscription state not known yet. Events wait in memory.
    case unknown
    case tracked
    /// Not a subscriber. Events are dropped and nothing is stored.
    case notTracked
}

/// Token returned by `addObserver`; pass it to `removeObserver`.
public struct EventObserverToken: Hashable, Sendable {
    let id = UUID()
}

/// Told about queue changes, on the SDK queue. The uploader is the only listener.
protocol EventPipelineListener: AnyObject {
    /// An event was written to disk; `queueCount` is the new number of events on disk.
    func pipelineDidStore(queueCount: Int)
    /// The user opted out; the disk queue has just been cleared.
    func pipelineDidOptOut()
    /// The kill switch fired; the disk queue has just been cleared and nothing more is captured
    /// until the next start-up.
    func pipelineDidDisable()
}

/// Told when the tracking gate opens or closes, on the SDK queue. `RemoteChecks` is the only listener:
/// `GET /offers` follows the same gate as events.
protocol TrackingGateListener: AnyObject {
    func trackingGateDidChange(isOpen: Bool)
}

/// The single path every event takes: gate → sequence number → disk → log → observers.
/// All state lives on one serial queue, so collectors can call `track` from any thread.
final class EventPipeline: @unchecked Sendable {
    private struct Pending {
        let name: EventName
        let properties: [String: JSONValue]
        let timestamp: Date
        let sessionId: String?
        let userId: String?
        let anonymousId: String
    }

    struct Envelope {
        var sdkVersion: String
        var appVersion: String
        var appBuild: String
        var osVersion: String
    }

    static let maxBufferedEvents = 500
    private static let seqKey = "seq"
    private static let userIdKey = "user_id"
    private static let optedOutKey = "opted_out"
    static let anonymousIdKey = "anonymous_id"
    /// The anonymous ID for which an `identify` event has been stored. One value, so a new
    /// anonymous ID automatically means "not sent yet".
    static let identitySentKey = "identify_sent_for_anonymous_id"

    let queue: DispatchQueue
    private let storeProvider: () -> EventStore
    /// Created on the SDK queue at first use, so `configure` does no disk I/O on the caller's thread.
    private lazy var store: EventStore = storeProvider()
    private let defaults: UserDefaults
    private let logger: SDKLogger
    private let envelope: Envelope
    private let installIdProvider: () -> String
    private lazy var installId: String = installIdProvider()

    private var trackingState: TrackingState
    private var buffer: [Pending] = []
    private var observers: [EventObserverToken: (Event) -> Void] = [:]
    private var sessionId: String?
    private var userId: String?
    private var anonymousIdValue: String
    /// Mirror of the anonymous ID that can be read from any thread without touching the queue.
    private let anonymousIdLock = NSLock()
    private var anonymousIdMirror: String
    private var optedOut: Bool
    /// Mirror of `optedOut` that can be read from any thread without touching the queue.
    private let optedOutLock = NSLock()
    private var optedOutMirror: Bool
    /// Kill switch (`401` from the Events API). In memory only: the next start-up checks again.
    private var disabled = false
    private let disabledLock = NSLock()
    private var disabledMirror = false
    private static let queueKey = DispatchSpecificKey<Bool>()
    /// Set once by `SDKCore` before `start()`; only used on the SDK queue.
    weak var listener: EventPipelineListener?
    /// Set once by `SDKCore` before `start()`; only used on the SDK queue.
    weak var trackingGateListener: TrackingGateListener?

    init(
        queue: DispatchQueue,
        storeProvider: @escaping () -> EventStore,
        defaults: UserDefaults,
        logger: SDKLogger,
        envelope: Envelope,
        trackingScope: Configuration.TrackingScope,
        installIdProvider: @escaping () -> String
    ) {
        self.queue = queue
        self.storeProvider = storeProvider
        self.defaults = defaults
        self.logger = logger
        self.envelope = envelope
        self.installIdProvider = installIdProvider
        self.trackingState = trackingScope == .everyone ? .tracked : .unknown
        self.userId = defaults.string(forKey: Self.userIdKey)
        // Generated at configure and kept in the SDK's UserDefaults: survives restarts, not a reinstall.
        let anonymousId: String
        if let stored = defaults.string(forKey: Self.anonymousIdKey), !stored.isEmpty {
            anonymousId = stored
        } else {
            anonymousId = Self.newAnonymousId()
            defaults.set(anonymousId, forKey: Self.anonymousIdKey)
        }
        self.anonymousIdValue = anonymousId
        self.anonymousIdMirror = anonymousId
        self.optedOut = defaults.bool(forKey: Self.optedOutKey)
        self.optedOutMirror = optedOut
        queue.setSpecific(key: Self.queueKey, value: true)
    }

    /// Runs `work` on the SDK queue and waits, or inline when already on it
    /// (for example when called from inside an event observer).
    private func onQueue<T>(_ work: () -> T) -> T {
        DispatchQueue.getSpecific(key: Self.queueKey) == true ? work() : queue.sync(execute: work)
    }

    // MARK: Tracking

    /// Records an event. Safe from any thread; never blocks the caller.
    /// - Parameters:
    ///   - timestamp: when the event happened. Pass a past date for events discovered late
    ///     (for example a `session_end` found on the next launch).
    ///   - sessionId: overrides the current session, for events that belong to an older one.
    ///     `.some(nil)` means "no session".
    func track(
        _ name: EventName,
        properties: [String: JSONValue] = [:],
        timestamp: Date = Date(),
        sessionId sessionOverride: String?? = nil
    ) {
        queue.async { [self] in
            enqueue(name, properties: properties, timestamp: timestamp, sessionId: sessionOverride)
        }
    }

    /// The body of `track`, on the SDK queue.
    private func enqueue(
        _ name: EventName,
        properties: [String: JSONValue],
        timestamp: Date = Date(),
        sessionId sessionOverride: String?? = nil
    ) {
        guard !optedOut, !disabled else { return }
        let pending = Pending(
            name: name,
            properties: properties,
            timestamp: timestamp,
            sessionId: sessionOverride ?? sessionId,
            userId: userId,
            anonymousId: anonymousIdValue
        )
        switch trackingState {
        case .tracked:
            commit(pending)
        case .unknown:
            buffer.append(pending)
            if buffer.count > Self.maxBufferedEvents { buffer.removeFirst() }
        case .notTracked:
            logger.debug("dropped \(name.rawValue): user is not in tracking scope")
        }
    }

    /// Sets the session that later events are stamped with. `nil` means no session is open.
    func setSessionId(_ id: String?) {
        queue.async { [self] in sessionId = id }
    }

    /// Called by the subscription collector whenever it learns whether the user is in scope.
    /// Ignored when the SDK is configured with `trackingScope: .everyone`.
    func setTrackingState(_ state: TrackingState, scope: Configuration.TrackingScope) {
        guard scope == .subscribersOnly else { return }
        queue.async { [self] in
            guard state != trackingState else { return }
            trackingState = state
            logger.info("tracking state: \(state)")
            switch state {
            case .tracked:
                let waiting = buffer
                buffer.removeAll()
                waiting.forEach(commit)
                sendIdentityIfNeeded()
            case .notTracked:
                buffer.removeAll()
            case .unknown:
                break
            }
            if state != .unknown { trackingGateListener?.trackingGateDidChange(isOpen: state == .tracked) }
        }
    }

    /// True while the user is in tracking scope (always with `trackingScope: .everyone`).
    /// Anything that sends data about the user (events, `GET /offers`) checks this. SDK queue only.
    var isTracked: Bool { trackingState == .tracked }

    // MARK: Identity

    /// Called once from `SDKCore.start()`. With `trackingScope: .everyone` the user is tracked
    /// from the start, so the identity goes out now; otherwise it waits for the gate.
    func start() {
        queue.async { [self] in
            if trackingState == .tracked { sendIdentityIfNeeded() }
        }
    }

    /// The current anonymous ID. Safe from any thread.
    var anonymousId: String {
        anonymousIdLock.lock()
        defer { anonymousIdLock.unlock() }
        return anonymousIdMirror
    }

    /// `identify(userId)`: sets the user ID and emits `identify`, unless it is already the
    /// current user ID. Ignored after an opt-out.
    func identify(userId id: String) {
        queue.async { [self] in
            guard !optedOut, id != userId else { return }
            storeUserId(id)
            enqueue(.identify, properties: ["user_id": .string(id)])
        }
    }

    /// Logout: clears the user ID and starts a new anonymous ID, whose identity goes out again
    /// as soon as the user is tracked. Events already captured keep the old anonymous ID.
    func reset() {
        queue.async { [self] in
            storeUserId(nil)
            setAnonymousId(Self.newAnonymousId())
            defaults.removeObject(forKey: Self.identitySentKey)
            if trackingState == .tracked { sendIdentityIfNeeded() }
        }
    }

    func setUserId(_ id: String?) {
        queue.async { [self] in storeUserId(id) }
    }

    /// SDK queue only.
    private func storeUserId(_ id: String?) {
        // After an opt-out nothing about the user may be stored again.
        let id = optedOut ? nil : id
        userId = id
        if let id {
            defaults.set(id, forKey: Self.userIdKey)
        } else {
            defaults.removeObject(forKey: Self.userIdKey)
        }
    }

    /// SDK queue only.
    private func setAnonymousId(_ id: String) {
        anonymousIdValue = id
        defaults.set(id, forKey: Self.anonymousIdKey)
        anonymousIdLock.lock()
        anonymousIdMirror = id
        anonymousIdLock.unlock()
    }

    /// Emits `identify` (with the current user ID, or null) once per anonymous ID, while the
    /// user is tracked. SDK queue only.
    private func sendIdentityIfNeeded() {
        guard !optedOut, trackingState == .tracked,
              defaults.string(forKey: Self.identitySentKey) != anonymousIdValue else { return }
        enqueue(.identify, properties: ["user_id": userId.map(JSONValue.string) ?? .null])
    }

    private static func newAnonymousId() -> String { UUID().uuidString.lowercased() }

    func setOptedOut(_ value: Bool) {
        optedOutLock.lock()
        optedOutMirror = value
        optedOutLock.unlock()
        queue.async { [self] in
            optedOut = value
            defaults.set(value, forKey: Self.optedOutKey)
            if value {
                buffer.removeAll()
                store.clear()
                userId = nil
                defaults.removeObject(forKey: Self.userIdKey)
                // The anonymous ID is kept, but its `identify` may have been in the cleared
                // queue, so it is sent again after `optIn`.
                defaults.removeObject(forKey: Self.identitySentKey)
                logger.info("opted out: queue and user ID cleared")
                listener?.pipelineDidOptOut()
            } else {
                sendIdentityIfNeeded()
            }
        }
    }

    var isOptedOut: Bool {
        optedOutLock.lock()
        defer { optedOutLock.unlock() }
        return optedOutMirror
    }

    // MARK: Kill switch

    /// The kill switch: stops capturing and drops the queue until the next start-up. The user ID,
    /// anonymous ID and opt-out choice are kept. Safe from any thread.
    func disable() {
        disabledLock.lock()
        disabledMirror = true
        disabledLock.unlock()
        queue.async { [self] in
            guard !disabled else { return }
            disabled = true
            buffer.removeAll()
            store.clear()
            // Its `identify` may have been in the dropped queue: send it again after the next start-up.
            defaults.removeObject(forKey: Self.identitySentKey)
            logger.error("kill switch: capture stopped and queue dropped until the next launch")
            listener?.pipelineDidDisable()
        }
    }

    /// True after the kill switch fired in this run. Safe from any thread.
    var isDisabled: Bool {
        disabledLock.lock()
        defer { disabledLock.unlock() }
        return disabledMirror
    }

    /// The logged-in user ID, if any. SDK queue only.
    var currentUserId: String? { userId }

    // MARK: Observers and debugging

    /// Observers are called on the SDK queue, once per committed event.
    func addObserver(_ handler: @escaping (Event) -> Void) -> EventObserverToken {
        let token = EventObserverToken()
        queue.async { [self] in observers[token] = handler }
        return token
    }

    func removeObserver(_ token: EventObserverToken) {
        queue.async { [self] in observers[token] = nil }
    }

    /// Every event currently in the on-disk queue. Blocks until earlier `track` calls are done.
    func queuedEvents() -> [Event] { onQueue { store.all() } }

    /// Waits for everything submitted so far. For tests.
    func waitUntilIdle() { onQueue {} }

    // MARK: Uploader access (SDK queue only)

    var storedCount: Int {
        return store.count
    }

    func oldestStored(maxEvents: Int, maxBytes: Int) -> [EventStore.StoredLine] {
        return store.oldest(maxEvents: maxEvents, maxBytes: maxBytes)
    }

    func removeStored(eventIds: Set<String>) {
        store.remove(eventIds: eventIds)
    }

    // MARK: Private

    private func commit(_ pending: Pending) {
        let seq = defaults.integer(forKey: Self.seqKey) + 1
        defaults.set(seq, forKey: Self.seqKey)
        let event = Event(
            eventId: UUID().uuidString.lowercased(),
            name: pending.name,
            timestamp: Timestamp.string(from: pending.timestamp),
            seq: seq,
            installId: installId,
            anonymousId: pending.anonymousId,
            userId: pending.userId,
            sessionId: pending.sessionId,
            schemaVersion: Event.schemaVersion,
            sdkVersion: envelope.sdkVersion,
            platform: "ios",
            appVersion: envelope.appVersion,
            appBuild: envelope.appBuild,
            osVersion: envelope.osVersion,
            properties: pending.properties
        )
        store.append(event)
        if event.name == .identify {
            defaults.set(pending.anonymousId, forKey: Self.identitySentKey)
        }
        logger.debug("event \(event.jsonString())")
        observers.values.forEach { $0(event) }
        listener?.pipelineDidStore(queueCount: store.count)
    }
}
