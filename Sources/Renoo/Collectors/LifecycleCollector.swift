import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// App opens, foreground / background, sessions and unclean exits (a previous run that was killed
/// or crashed without reaching the background).
///
/// The rules live in `LifecycleEngine` (UIKit-free, unit-tested). This class only turns UIKit
/// notifications into engine calls and forwards the resulting steps to the pipeline.
///
/// The engine runs synchronously on the calling thread (main), under a lock. It only touches
/// UserDefaults and the context cache, so it is cheap, and it means `setSessionId` reaches the
/// pipeline queue before any event the app tracks right after activation (e.g. the first
/// `viewDidAppear`). Running it on the SDK queue would hop twice and let those events overtake it.
/// It also makes the background mark persist before the app can be suspended.
///
/// Cold `app_open` is emitted on the first real activation of the process, not in `start()`:
/// a prewarmed or background-launched process runs `configure` without ever becoming active.
/// If `configure` runs after the app is already active (late init, Flutter channel), `start()`
/// handles that activation itself.
///
/// `last_active_at` for unclean exits: we can't see a crash, so the engine persists a "last
/// alive in the foreground" time on every transition, on resign-active, and from a slow heartbeat
/// (every 60 s with 15 s leeway, only while in the foreground; a suspended app runs no timers, so it
/// costs nothing in the background). The estimate is therefore at most ~75 s early. Anything
/// tighter would need per-event writes or frequent polling, which isn't worth the battery.
final class LifecycleCollector: Collector {
    static let heartbeatInterval: TimeInterval = 60

    private let environment: SDKEnvironment
    private let context: ContextCollector
    /// Guards `engine` and `heartbeat`.
    private let lock = NSLock()
    private lazy var engine = LifecycleEngine(
        defaults: environment.defaults,
        context: { [context] in context.snapshot() }
    )
    private var heartbeat: DispatchSourceTimer?
    /// Main thread only.
    private var tokens: [NSObjectProtocol] = []
    /// Set once by `SDKCore` before `start()`. Called on the calling (main) thread after the
    /// lifecycle events are queued, so the uploader's flush runs after they reach disk.
    var onBecameActive: (() -> Void)?
    var onEnteredBackground: (() -> Void)?

    init(environment: SDKEnvironment, context: ContextCollector) {
        self.environment = environment
        self.context = context
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
        heartbeat?.cancel()
    }

    func start() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.becameActive()
            },
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.withEngine { $0.recordActivity() }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.enteredBackground()
            },
            center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
                self?.willTerminate()
            },
        ]
        // `start()` runs on the main thread, so no activation can slip in between subscribing and this check.
        // Prewarmed and background launches are not `.active`: their cold open waits for the notification.
        if HostApplication.shared?.applicationState == .active {
            becameActive()
        }
        #endif
    }

    // MARK: Entry points (internal so tests can drive them without UIKit)

    func becameActive() {
        withEngine { engine in
            apply(engine.didBecomeActive())
            startHeartbeat()
        }
        onBecameActive?()
    }

    func enteredBackground() {
        withEngine { engine in
            apply(engine.didEnterBackground())
            stopHeartbeat()
        }
        onEnteredBackground?()
        #if canImport(UIKit) && !os(watchOS)
        // State is already persisted; ask for a little time so the queued events reach disk too.
        guard let app = HostApplication.shared else { return }
        var task = UIBackgroundTaskIdentifier.invalid
        task = app.beginBackgroundTask(withName: "Renoo.lifecycle") {
            app.endBackgroundTask(task)
            task = .invalid
        }
        environment.queue.async {
            DispatchQueue.main.async {
                guard task != .invalid else { return }
                app.endBackgroundTask(task)
                task = .invalid
            }
        }
        #endif
    }

    /// Normally the app is already in the background here. If it is terminated straight from the
    /// foreground, record a background so the next launch doesn't report an unclean exit, then
    /// give the queue at most 0.5 s to write the events: the process is about to exit anyway.
    func willTerminate() {
        withEngine { engine in
            apply(engine.didEnterBackground())
            stopHeartbeat()
        }
        let done = DispatchSemaphore(value: 0)
        environment.queue.async { done.signal() }
        _ = done.wait(timeout: .now() + 0.5)
    }

    /// Waits for queued pipeline work. For tests.
    func waitUntilIdle() { environment.queue.sync {} }

    // MARK: Private

    private func withEngine(_ work: (LifecycleEngine) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        work(engine)
    }

    /// Called with `lock` held. `track` and `setSessionId` only enqueue, so order is preserved.
    private func apply(_ steps: [LifecycleStep]) {
        let pipeline = environment.pipeline
        for step in steps {
            switch step {
            case .setSession(let id):
                pipeline.setSessionId(id)
            case let .emit(name, properties, timestamp, sessionId):
                pipeline.track(name, properties: properties, timestamp: timestamp, sessionId: sessionId)
            }
        }
    }

    /// Called with `lock` held.
    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: environment.queue)
        let interval = Self.heartbeatInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(15))
        timer.setEventHandler { [weak self] in self?.withEngine { $0.recordActivity() } }
        timer.resume()
        heartbeat = timer
    }

    /// Called with `lock` held.
    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }
}
