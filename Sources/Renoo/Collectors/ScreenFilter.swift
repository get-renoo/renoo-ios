import Foundation

/// Decides whether a view controller that just appeared is a screen, and what it is called.
/// Pure (no UIKit) so the rules are unit-tested on macOS; the UIKit glue fills in `Candidate`.
enum ScreenFilter {
    struct Candidate: Equatable {
        /// The Objective-C runtime name (`NSStringFromClass`), e.g. `MyApp.HomeViewController`.
        var className: String
        /// Navigation, tab bar, split or page view controller.
        var isContainer = false
        /// Alert controller, input (keyboard) view controller, or another known system type.
        var isSystemType = false
        /// The class comes from an OS framework (its bundle lives under /System or /usr).
        var isFromSystemBundle = false
        /// Nil when the controller has no parent; otherwise whether that parent is a container.
        var parentIsContainer: Bool?
    }

    /// The screen name, or nil when the controller should not produce a `screen_view`.
    static func screenName(for candidate: Candidate) -> String? {
        if candidate.isContainer || candidate.isSystemType || candidate.isFromSystemBundle { return nil }
        // A child of a custom container is part of a bigger screen; the container is the screen.
        if candidate.parentIsContainer == false { return nil }
        let raw = candidate.className
        if raw.isEmpty || isSystemClassName(raw) { return nil }
        let name = stripModule(raw)
        if wrapperHostClassNames.contains(name) { return nil }
        return name.isEmpty ? nil : name
    }

    /// The single native controller a cross-platform framework renders everything inside.
    /// It is not a screen: the framework's wrapper reports the real screens by name.
    static let wrapperHostClassNames: Set<String> = ["FlutterViewController"]

    /// Private and public UIKit / SwiftUI classes. UIKit and private classes are matched by name as
    /// a backstop in case the bundle check misses one (e.g. classes created at runtime).
    static func isSystemClassName(_ name: String) -> Bool {
        if name.hasPrefix("_") { return true }  // _UI…, _SwiftUI…, mangled private runtime classes
        if name.hasPrefix("UI"), name.count > 2,
           let third = name.dropFirst(2).first, third.isUppercase { return true }  // UIInputWindowController, UIAlertController…
        if name.hasPrefix("SwiftUI.") || name.contains("HostingController") { return true }  // SwiftUI: use .renooScreen
        return false
    }

    /// `MyApp.HomeViewController` → `HomeViewController`; `MyApp.Outer.Inner` → `Outer.Inner`.
    /// Generic arguments keep their own module prefixes out: `MyApp.List<MyApp.Item>` → `List`.
    static func stripModule(_ name: String) -> String {
        var base = Substring(name)
        if let angle = base.firstIndex(of: "<") { base = base[..<angle] }
        if let dot = base.firstIndex(of: ".") { base = base[base.index(after: dot)...] }
        return String(base).trimmingCharacters(in: .whitespaces)
    }
}
