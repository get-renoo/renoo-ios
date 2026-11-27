import XCTest
@testable import Renoo

final class ScreenFilterTests: XCTestCase {
    private typealias C = ScreenFilter.Candidate

    func testAppScreensKeepTheirNameWithoutModule() {
        XCTAssertEqual(ScreenFilter.screenName(for: C(className: "MyApp.HomeViewController")), "HomeViewController")
        XCTAssertEqual(ScreenFilter.screenName(for: C(className: "MyApp.Outer.Inner")), "Outer.Inner")
        XCTAssertEqual(ScreenFilter.screenName(for: C(className: "MyApp.ListVC<MyApp.Item>")), "ListVC")
        XCTAssertEqual(ScreenFilter.screenName(for: C(className: "LegacyObjCViewController")), "LegacyObjCViewController")
        // Flutter's host controller is not a screen; the Flutter wrapper reports the real ones.
        XCTAssertNil(ScreenFilter.screenName(for: C(className: "FlutterViewController")))
    }

    func testReactNativePlumbingIsSkipped() {
        // react-native-screens wraps every native-stack screen in an RNSScreen controller.
        XCTAssertNil(ScreenFilter.screenName(for: C(className: "RNSScreen", parentIsContainer: true)))
        XCTAssertNil(ScreenFilter.screenName(for: C(className: "RNSTabsScreenViewController")))
        XCTAssertNil(ScreenFilter.screenName(for: C(className: "RCTFabricModalHostViewController")))
        XCTAssertNil(ScreenFilter.screenName(for: C(className: "RCTModalHostViewController")))
        // An app's own screens with similar names still count.
        XCTAssertEqual(ScreenFilter.screenName(for: C(className: "MyApp.RNSettingsViewController")), "RNSettingsViewController")
        XCTAssertEqual(ScreenFilter.screenName(for: C(className: "MyApp.Rcthing")), "Rcthing")
    }

    func testScreensInsideContainersCount() {
        XCTAssertEqual(ScreenFilter.screenName(for: C(className: "MyApp.Settings", parentIsContainer: true)), "Settings")
    }

    func testChildrenOfCustomContainersAreSkipped() {
        XCTAssertNil(ScreenFilter.screenName(for: C(className: "MyApp.CardChild", parentIsContainer: false)))
    }

    func testContainersAndSystemTypesAreSkipped() {
        XCTAssertNil(ScreenFilter.screenName(for: C(className: "MyApp.MainNav", isContainer: true)))
        XCTAssertNil(ScreenFilter.screenName(for: C(className: "MyApp.MyAlert", isSystemType: true)))
        XCTAssertNil(ScreenFilter.screenName(for: C(className: "SFSafariViewController", isFromSystemBundle: true)))
    }

    func testSystemClassNamesAreSkipped() {
        for name in ["UINavigationController", "UIInputWindowController", "UIAlertController",
                     "UICompatibilityInputViewController", "_UIRemoteInputViewController",
                     "_UIAlertControllerTextFieldViewController", "UISystemKeyboardDockController",
                     "SwiftUI.UIHostingController<SwiftUI.AnyView>", "_TtGC7SwiftUI19UIHostingController",
                     "MyApp.PresentationHostingController"] {
            XCTAssertNil(ScreenFilter.screenName(for: C(className: name)), name)
        }
    }

    func testUIPrefixOnlyMatchesTheUIKitPattern() {
        // "UIKit-looking" means UI followed by an uppercase letter; "Uikit…" or "UI" alone are app names.
        XCTAssertEqual(ScreenFilter.screenName(for: C(className: "UiSettingsScreen")), "UiSettingsScreen")
        XCTAssertNil(ScreenFilter.screenName(for: C(className: "")))
    }
}
