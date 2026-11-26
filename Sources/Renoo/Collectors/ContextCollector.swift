import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Device and app context, attached to `session_start`. Also emits `push_permission_changed`.
///
/// `snapshot()` only reads a lock-protected cache. The cache is refreshed at `start()` and on every
/// `willEnterForeground` (which comes before the `didBecomeActive` that may open a session):
/// - main thread, cheap: locale, timezone, low power mode, dark mode;
/// - SDK queue: install age and reinstall flag (the identity may touch the Keychain). The values
///   are also kept in defaults so a `session_start` right at `configure` (app already active, before
///   the queue has read the identity) still has them from the previous run;
/// - async callbacks: network type (`NWPathMonitor`, live) and push permission
///   (`getNotificationSettings`, read only, never requested). Until the callback lands, the
///   snapshot carries the last status seen by an earlier run (or null on the very first run).
final class ContextCollector: Collector {
    private let environment: SDKEnvironment
    private let lock = NSLock()
    private var cache = Cache()
    private var pathMonitor: NWPathMonitor?
    private let pushTracker: PushPermissionTracker
    /// Main thread only.
    private var tokens: [NSObjectProtocol] = []

    private struct Cache {
        var deviceModel: String = ContextCollector.deviceModel()
        var locale: String?
        var timezone: String?
        var networkType = "unknown"
        var lowPowerMode: Bool?
        var darkMode: Bool?
        var pushPermission: String?
        var installDate: Date?
        var isReinstall: Bool?
    }

    init(environment: SDKEnvironment) {
        self.environment = environment
        self.pushTracker = PushPermissionTracker(defaults: environment.defaults)
        cache.pushPermission = pushTracker.lastStatus
        cache.installDate = environment.defaults.object(forKey: Self.installDateKey) as? Date
        cache.isReinstall = environment.defaults.object(forKey: Self.isReinstallKey) as? Bool
    }

    private static let installDateKey = "context_install_date"
    private static let isReinstallKey = "context_is_reinstall"

    deinit {
        pathMonitor?.cancel()
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let type = Self.networkType(path)
            self?.update { $0.networkType = type }
        }
        monitor.start(queue: environment.queue)
        pathMonitor = monitor

        #if canImport(UIKit) && !os(watchOS)
        tokens.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.refresh() })
        #endif
        refresh()
    }

    /// The current context object. Cheap and non-blocking: returns cached values. Any thread.
    func snapshot(now: Date = Date()) -> [String: JSONValue] {
        lock.lock()
        let cache = self.cache
        lock.unlock()
        let days = cache.installDate.map { Self.daysSinceInstall(installDate: $0, now: now) }
        return [
            "device_model": .string(cache.deviceModel),
            "locale": .optional(cache.locale),
            "timezone": .optional(cache.timezone),
            "network_type": .string(cache.networkType),
            "low_power_mode": .optional(cache.lowPowerMode),
            "dark_mode": .optional(cache.darkMode),
            "push_permission": .optional(cache.pushPermission),
            "days_since_install": .optional(days),
            "is_reinstall": .optional(cache.isReinstall),
        ]
    }

    /// Call on the main thread.
    func refresh() {
        let locale = Self.bcp47(Locale.current)
        let timezone = TimeZone.current.identifier
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let dark = Self.isDarkMode()
        update {
            $0.locale = locale
            $0.timezone = timezone
            $0.lowPowerMode = lowPower
            $0.darkMode = dark
        }

        environment.queue.async { [weak self] in
            guard let self else { return }
            let identity = self.environment.identity
            let installDate = identity.currentInstallDate
            let reinstall = identity.isReinstall
            self.environment.defaults.set(installDate, forKey: Self.installDateKey)
            self.environment.defaults.set(reinstall, forKey: Self.isReinstallKey)
            self.update {
                $0.installDate = installDate
                $0.isReinstall = reinstall
            }
        }

        readPushPermission()
    }

    // MARK: Push permission

    private func readPushPermission() {
        #if canImport(UserNotifications) && !os(macOS)
        // `UNUserNotificationCenter.current()` raises outside a real app bundle (e.g. a test runner).
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let status = Self.pushStatus(settings.authorizationStatus) else { return }
            self?.environment.queue.async { self?.pushStatusRead(status) }
        }
        #endif
    }

    /// SDK queue. Internal so tests can feed statuses.
    func pushStatusRead(_ status: String) {
        update { $0.pushPermission = status }
        if let change = pushTracker.observe(status) {
            environment.pipeline.track(.pushPermissionChanged, properties: [
                "status": .string(change.status),
                "previous_status": .string(change.previous),
            ])
        }
    }

    #if canImport(UserNotifications) && !os(macOS)
    static func pushStatus(_ status: UNAuthorizationStatus) -> String? {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "not_determined"
        case .provisional: return "provisional"
        #if os(iOS)
        case .ephemeral: return "ephemeral"
        #endif
        @unknown default: return nil
        }
    }
    #endif

    // MARK: Helpers

    private func update(_ change: (inout Cache) -> Void) {
        lock.lock()
        change(&cache)
        lock.unlock()
    }

    /// Whole 24-hour periods since the current install (not the first one on the device), never negative.
    static func daysSinceInstall(installDate: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(installDate) / 86_400))
    }

    /// BCP 47 language tag (`en-US`, `zh-Hans-CN`). `nil` if Foundation returns an empty tag.
    static func bcp47(_ locale: Locale) -> String? {
        let tag = locale.identifier(.bcp47)
        return tag.isEmpty ? nil : tag
    }

    static func networkType(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "none" }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        return "unknown"
    }

    /// Hardware identifier such as `iPhone17,1`. On the simulator, the simulated device's identifier.
    static func deviceModel(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let simulated = environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }

    /// The system appearance. Main thread. Nil where it can't be read.
    private static func isDarkMode() -> Bool? {
        #if canImport(UIKit) && !os(watchOS)
        let scene = HostApplication.shared?.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let traits = scene?.traitCollection ?? UITraitCollection.current
        switch traits.userInterfaceStyle {
        case .dark: return true
        case .light: return false
        default: return nil
        }
        #else
        return nil
        #endif
    }
}

/// Remembers the last push permission status across runs and reports changes.
/// The first status ever seen is stored silently: there is nothing to compare it with.
struct PushPermissionTracker {
    static let key = "push_permission_status"
    let defaults: UserDefaults

    var lastStatus: String? { defaults.string(forKey: Self.key) }

    /// Stores `status`; returns the change when it differs from the previously stored one.
    func observe(_ status: String) -> (status: String, previous: String)? {
        let previous = lastStatus
        guard previous != status else { return nil }
        defaults.set(status, forKey: Self.key)
        guard let previous else { return nil }
        return (status, previous)
    }
}
