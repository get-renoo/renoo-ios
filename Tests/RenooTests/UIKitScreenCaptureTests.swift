#if canImport(UIKit) && !os(watchOS)
import UIKit
import XCTest
@testable import Renoo

final class CaptureHomeViewController: UIViewController {
    var originalCalled = 0
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        originalCalled += 1
    }
}

final class CaptureChildViewController: UIViewController {}
final class CaptureCustomContainer: UIViewController {}
private final class CapturePrivateViewController: UIViewController {}

/// Runs only on iOS (simulator): exercises the real `viewDidAppear(_:)` swizzle.
@MainActor
final class UIKitScreenCaptureTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var core: SDKCore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        var configuration = Configuration(apiKey: "pk_test", purchaseHandler: { _ in .cancelled })
        configuration.trackingScope = .everyone
        configuration.logLevel = .none
        core = SDKCore(configuration: configuration, defaults: defaults, storeDirectory: directory)
        core.screens.start()
        core.screens.start()  // idempotent
    }

    override func tearDown() {
        core = nil
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func screens() -> [String] {
        core.environment.pipeline.queuedEvents().compactMap {
            guard $0.name == .screenView, case .string(let name)? = $0.properties["screen_name"] else { return nil }
            XCTAssertEqual($0.properties["source"], "uikit")
            return name
        }
    }

    func testAppScreenIsCapturedOnceAndOriginalRuns() {
        XCTAssertTrue(UIKitScreenCapture.isInstalled)
        let home = CaptureHomeViewController()
        home.viewDidAppear(false)
        XCTAssertEqual(home.originalCalled, 1)
        XCTAssertEqual(screens(), ["CaptureHomeViewController"])
    }

    func testPrivateSwiftClassGetsReadableName() {
        CapturePrivateViewController().viewDidAppear(false)
        XCTAssertEqual(screens(), ["CapturePrivateViewController"])
    }

    func testContainersAndTheirScreens() {
        let child = CaptureChildViewController()
        let navigation = UINavigationController(rootViewController: child)
        navigation.viewDidAppear(false)
        child.viewDidAppear(false)

        let container = CaptureCustomContainer()
        let embedded = CaptureHomeViewController()
        container.addChild(embedded)
        embedded.didMove(toParent: container)
        container.viewDidAppear(false)
        embedded.viewDidAppear(false)

        XCTAssertEqual(screens(), ["CaptureChildViewController", "CaptureCustomContainer"])
    }

    func testSystemControllersAreSkipped() {
        UIAlertController(title: "t", message: nil, preferredStyle: .alert).viewDidAppear(false)
        UITabBarController().viewDidAppear(false)
        UIViewController().viewDidAppear(false)
        XCTAssertEqual(screens(), [])
    }

    func testAnotherSwizzlerOnTopStillReachesUs() {
        let selector = #selector(UIViewController.viewDidAppear(_:))
        guard let method = class_getInstanceMethod(UIViewController.self, selector) else { return XCTFail() }
        typealias Fn = @convention(c) (UIViewController, Selector, Bool) -> Void
        let ours = method_getImplementation(method)
        var otherCalls = 0
        let other: @convention(block) (UIViewController, Bool) -> Void = { controller, animated in
            otherCalls += 1
            unsafeBitCast(ours, to: Fn.self)(controller, selector, animated)
        }
        method_setImplementation(method, imp_implementationWithBlock(other))
        defer { method_setImplementation(method, ours) }

        let home = CaptureHomeViewController()
        home.viewDidAppear(false)
        XCTAssertEqual(otherCalls, 1)
        XCTAssertEqual(home.originalCalled, 1)
        XCTAssertEqual(screens(), ["CaptureHomeViewController"])
    }
}
#endif
