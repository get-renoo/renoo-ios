#if canImport(SwiftUI)
import SwiftUI

private struct RenooScreenModifier: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        content.onAppear { Renoo.trackScreen(name, source: .swiftui) }
    }
}

public extension View {
    /// Records a `screen_view` (source `swiftui`) each time this view appears.
    ///
    /// ```swift
    /// SettingsView().renooScreen("Settings")
    /// ```
    func renooScreen(_ name: String) -> some View {
        modifier(RenooScreenModifier(name: name))
    }
}
#endif
