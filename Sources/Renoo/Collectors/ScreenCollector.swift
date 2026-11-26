import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Where a screen view came from.
public enum ScreenSource: String, Sendable {
    case uikit, swiftui, manual, flutter
    case reactNative = "react_native"
}

/// Screen views: manual (`Renoo.trackScreen`), SwiftUI (`.renooScreen(_:)`) and,
/// when `configuration.automaticScreenTracking` is on, automatic UIKit capture through a one-time
/// swizzle of `UIViewController.viewDidAppear(_:)`. Which controllers count is `ScreenFilter`.
final class ScreenCollector: Collector {
    static let maxNameLength = 100

    private let environment: SDKEnvironment
    private let lock = NSLock()
    private var lastScreenName: String?

    init(environment: SDKEnvironment) { self.environment = environment }

    func start() {
        #if canImport(UIKit) && !os(watchOS)
        guard environment.configuration.automaticScreenTracking else { return }
        UIKitScreenCapture.install(for: self)
        #endif
    }

    func trackScreen(name: String, source: ScreenSource) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ScreenCollector.maxNameLength))
        guard !trimmed.isEmpty else { return }
        lock.lock()
        let previous = lastScreenName
        lastScreenName = trimmed
        lock.unlock()
        environment.pipeline.track(.screenView, properties: [
            "screen_name": .string(trimmed),
            "source": .string(source.rawValue),
            "previous_screen_name": .optional(previous),
        ])
    }
}

#if canImport(UIKit) && !os(watchOS)
/// The `viewDidAppear(_:)` hook. Process-wide: installed at most once, routed to the current collector.
///
/// Safety:
/// - Idempotent: guarded by a lock and a flag; never reinstalled, even after a reconfigure.
/// - Plays well with other swizzlers: it replaces only the implementation on `UIViewController`
///   itself (`method_setImplementation`) and always calls the implementation that was there
///   before, whoever installed it. Someone swizzling after us chains to our block the same way.
/// - Our work runs after the original and never throws; a failure to find the method just
///   disables auto capture.
enum UIKitScreenCapture {
    private typealias ViewDidAppear = @convention(c) (UIViewController, Selector, Bool) -> Void

    private static let lock = NSLock()
    private static var installed = false
    private static weak var collector: ScreenCollector?
    /// Per-class decision cache (name or "not a screen"). Main thread only, like `viewDidAppear`.
    private static var classCache: [ObjectIdentifier: String?] = [:]

    static var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    static func install(for collector: ScreenCollector) {
        lock.lock()
        defer { lock.unlock() }
        self.collector = collector
        guard !installed else { return }

        let selector = #selector(UIViewController.viewDidAppear(_:))
        guard let method = class_getInstanceMethod(UIViewController.self, selector) else { return }
        // Captured once, before we replace it. `original` is whatever is there now (UIKit's, or
        // another SDK's swizzle); we always call it first.
        let original = unsafeBitCast(method_getImplementation(method), to: ViewDidAppear.self)
        let block: @convention(block) (UIViewController, Bool) -> Void = { controller, animated in
            original(controller, selector, animated)
            UIKitScreenCapture.didAppear(controller)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        installed = true
    }

    private static func didAppear(_ controller: UIViewController) {
        lock.lock()
        let target = collector
        lock.unlock()
        guard let target, let name = screenName(for: controller) else { return }
        target.trackScreen(name: name, source: .uikit)
    }

    static func screenName(for controller: UIViewController) -> String? {
        // The parent can change per instance, so only the class-level part is cached.
        if let parent = controller.parent, !isContainer(parent) { return nil }
        let key = ObjectIdentifier(type(of: controller))
        if Thread.isMainThread, let cached = classCache[key] { return cached }
        let cls: AnyClass = type(of: controller)
        let fromSystem = isFromSystemBundle(cls)
        var className = NSStringFromClass(cls)
        // Private, fileprivate and generic Swift classes get mangled runtime names (`_TtC…`).
        // For the app's own classes use the Swift name instead (no module prefix).
        if className.hasPrefix("_Tt"), !fromSystem {
            className = String(describing: cls)
        }
        let candidate = ScreenFilter.Candidate(
            className: className,
            isContainer: isContainer(controller),
            isSystemType: isSystemType(controller),
            isFromSystemBundle: fromSystem,
            parentIsContainer: controller.parent.map(isContainer)
        )
        let name = ScreenFilter.screenName(for: candidate)
        if Thread.isMainThread { classCache[key] = .some(name) }
        return name
    }

    private static func isContainer(_ controller: UIViewController) -> Bool {
        controller is UINavigationController || controller is UITabBarController
            || controller is UISplitViewController || controller is UIPageViewController
    }

    private static func isSystemType(_ controller: UIViewController) -> Bool {
        controller is UIAlertController || controller is UIInputViewController
            || controller is UISearchController || controller is UIActivityViewController
            || controller is UIDocumentPickerViewController || controller is UIImagePickerController
    }

    private static func isFromSystemBundle(_ type: AnyClass) -> Bool {
        let path = Bundle(for: type).bundlePath
        // On the simulator the OS frameworks live under …/RuntimeRoot/System/Library/.
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.contains("/RuntimeRoot/System/")
            || path.contains("/RuntimeRoot/usr/")
    }
}
#endif
