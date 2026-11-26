#if canImport(UIKit) && !os(watchOS)
import UIKit

/// The host `UIApplication`, or nil where there is none (a unit-test runner, an app extension).
/// Looked up dynamically so the SDK also compiles for extension-only targets and never touches a
/// nil `UIApplication.shared`.
enum HostApplication {
    static var shared: UIApplication? {
        UIApplication.value(forKey: "sharedApplication") as? UIApplication
    }
}
#endif
