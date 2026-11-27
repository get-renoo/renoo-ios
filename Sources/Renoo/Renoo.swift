import Foundation

/// The public entry point. Every method is safe to call from any thread, never throws,
/// never blocks, and does nothing until `configure` has succeeded.
public enum Renoo {
    public static let sdkVersion = "0.1.1"

    private static let lock = NSLock()
    private static var _core: SDKCore?

    private static var core: SDKCore? {
        lock.lock()
        defer { lock.unlock() }
        return _core
    }

    /// Starts the SDK. Call once, on the main thread, as early as possible in app launch.
    /// A bad configuration disables the SDK instead of crashing.
    public static func configure(_ configuration: Configuration) {
        guard configuration.isValid else {
            SDKLogger(level: .error).error("configure: empty API key. The SDK is disabled.")
            return
        }
        guard Bundle.main.bundleURL.pathExtension != "appex" else {
            SDKLogger(level: .error).error("configure: app extensions are not supported. The SDK is disabled.")
            return
        }
        lock.lock()
        guard _core == nil else {
            lock.unlock()
            SDKLogger(level: configuration.logLevel).error("configure called twice; ignoring the second call.")
            return
        }
        let core = SDKCore(configuration: configuration)
        _core = core
        lock.unlock()

        if Thread.isMainThread {
            core.start()
        } else {
            DispatchQueue.main.async { core.start() }
        }
    }

    public static var isConfigured: Bool { core != nil }

    /// Links events to the client's user ID: the same ID they use in their billing SDK.
    /// Pass an opaque identifier, never an email address or a name. Call it after every login.
    /// Calling it again with the current user ID does nothing.
    public static func identify(userId: String) {
        guard let core, !userId.isEmpty, !core.environment.pipeline.isOptedOut else { return }
        core.environment.pipeline.identify(userId: userId)
    }

    /// Call on logout. Clears the user ID and starts a new anonymous ID; later events carry no
    /// user ID until `identify` is called again. Events already captured keep the old IDs.
    public static func reset() {
        guard let core else { return }
        core.environment.pipeline.reset()
        core.identityReset()
    }

    /// A random UUID (lowercase) generated at `configure` and sent on every event. It survives
    /// app restarts but not a reinstall, and `reset()` replaces it. `nil` before `configure`.
    /// For debugging, or to pass to a billing SDK such as RevenueCat.
    public static var anonymousId: String? { core?.environment.pipeline.anonymousId }

    /// Stops all tracking for this install and deletes the local queue and user ID.
    public static func optOut() {
        guard let core else { return }
        core.environment.pipeline.setOptedOut(true)
        core.optedOut()
    }

    /// Resumes tracking after `optOut`.
    public static func optIn() {
        core?.environment.pipeline.setOptedOut(false)
    }

    public static var isOptedOut: Bool { core?.environment.pipeline.isOptedOut ?? false }

    // MARK: Offers

    /// The offer the backend is holding for this user, or `nil` when there is none. Read-only;
    /// the SDK fetches it (`GET /offers`) at start-up and when the app returns to the foreground,
    /// at most every 6 hours. The SDK does not display it. `nil` before `configure`, in
    /// capture-only mode (no `ingestURL`), after `reset()` or `optOut()`, and after the kill switch.
    public static var pendingOffer: PendingOffer? { core?.pendingOffers.current }

    /// Calls `handler` on the main actor with the current pending offer straight away, then each
    /// time it changes (including to `nil`). Keep the token to stop with `removePendingOfferObserver`.
    /// Returns `nil` before `configure`.
    @discardableResult
    public static func addPendingOfferObserver(_ handler: @escaping PendingOfferObserver) -> PendingOfferObserverToken? {
        core?.pendingOffers.addObserver(handler)
    }

    public static func removePendingOfferObserver(_ token: PendingOfferObserverToken) {
        core?.pendingOffers.removeObserver(token)
    }

    /// Records a screen view by name. Use this where automatic capture can't see the screen;
    /// wrappers (Flutter, React Native) pass their own `source`.
    /// Use a static screen identifier (at most 100 characters), never text with user content.
    public static func trackScreen(_ name: String, source: ScreenSource = .manual) {
        core?.screens.trackScreen(name: name, source: source)
    }

    /// Calls `handler` for every captured event, on the SDK's background queue. Keep it quick.
    /// For debugging and test apps.
    @discardableResult
    public static func addEventObserver(_ handler: @escaping (Event) -> Void) -> EventObserverToken? {
        core?.environment.pipeline.addObserver(handler)
    }

    public static func removeEventObserver(_ token: EventObserverToken) {
        core?.environment.pipeline.removeObserver(token)
    }

    /// Every event waiting in the on-disk queue, oldest first. Blocks briefly; for debugging and tests.
    public static func queuedEvents() -> [Event] {
        core?.environment.pipeline.queuedEvents() ?? []
    }

    /// Test hook: replaces the running SDK. Not part of the public API.
    static func _setCoreForTesting(_ core: SDKCore?) {
        lock.lock()
        _core = core
        lock.unlock()
    }
}
