import XCTest
@testable import Renoo

final class InstallIdentityTests: XCTestCase {
    private var harness: TestHarness!
    private var suites: [String] = []

    override func setUp() {
        super.setUp()
        harness = TestHarness()
    }

    override func tearDown() {
        harness.tearDown()
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        super.tearDown()
    }

    /// A fresh UserDefaults suite: what the app sees after being deleted and reinstalled.
    private func freshDefaults() -> UserDefaults {
        let name = "test.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func identity(_ defaults: UserDefaults? = nil, now: Date = Date()) -> InstallIdentity {
        InstallIdentity(defaults: defaults ?? harness.defaults, logger: harness.logger, keychain: harness.keychain, now: { now })
    }

    func testFreshInstallCreatesAnIdAndSavesItToTheKeychain() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = identity(now: date)
        XCTAssertEqual(first.installId.count, 36)
        XCTAssertEqual(first.installId, first.installId.lowercased())
        XCTAssertEqual(first.firstInstallDate, date)
        XCTAssertEqual(first.currentInstallDate, date)
        XCTAssertEqual(first.idSource, .keychain)
        XCTAssertFalse(first.isReinstall)

        let record = try JSONDecoder().decode(InstallIdentity.Record.self, from: XCTUnwrap(harness.keychain.data))
        XCTAssertEqual(record, InstallIdentity.Record(installId: first.installId, firstInstallDate: date))
    }

    func testLaterLaunchKeepsTheSameIdentity() {
        let first = identity(now: Date(timeIntervalSince1970: 1_800_000_000))
        let id = first.installId
        let second = identity(now: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(second.installId, id)
        XCTAssertEqual(second.firstInstallDate, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(second.currentInstallDate, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(second.idSource, .keychain)
        XCTAssertFalse(second.isReinstall)
    }

    func testReinstallReusesTheKeychainIdAndStaysAReinstall() {
        let original = identity(now: Date(timeIntervalSince1970: 1_800_000_000))
        let id = original.installId

        let reinstalledDefaults = freshDefaults()
        let reinstall = identity(reinstalledDefaults, now: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(reinstall.installId, id)
        XCTAssertEqual(reinstall.firstInstallDate, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(reinstall.currentInstallDate, Date(timeIntervalSince1970: 1_900_000_000), "days_since_install restarts")
        XCTAssertEqual(reinstall.idSource, .keychain)
        XCTAssertTrue(reinstall.isReinstall)

        // Still a reinstall on the next launch of that install.
        XCTAssertTrue(identity(reinstalledDefaults).isReinstall)
    }

    func testKeychainFailureFallsBackToUserDefaults() {
        harness.keychain.failure = errSecMissingEntitlement
        let first = identity()
        let id = first.installId
        XCTAssertFalse(first.isReinstall)
        XCTAssertEqual(first.idSource, .random)
        XCTAssertEqual(identity().installId, id, "the UserDefaults copy keeps the ID stable")
        XCTAssertEqual(identity().idSource, .random)

        // Once the Keychain works again the existing ID is written into it.
        harness.keychain.failure = nil
        XCTAssertEqual(identity().installId, id)
        XCTAssertNotNil(harness.keychain.data)
        XCTAssertEqual(identity(freshDefaults()).installId, id)
    }

    func testCorruptKeychainRecordIsReplaced() {
        harness.keychain.data = Data("garbage".utf8)
        let identity = identity()
        XCTAssertFalse(identity.isReinstall)
        XCTAssertEqual(self.identity(freshDefaults()).installId, identity.installId)
    }

    func testResolvedOnceAndCachedAcrossThreads() {
        let identity = identity()
        var ids = [String](repeating: "", count: 50)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            let id = identity.installId
            _ = identity.firstInstallDate
            _ = identity.isReinstall
            lock.lock(); ids[index] = id; lock.unlock()
        }
        XCTAssertEqual(Set(ids).count, 1)
        XCTAssertEqual(harness.keychain.reads, 1)
        XCTAssertEqual(harness.keychain.writes, 1)
    }

    // MARK: InstallCollector

    func testInstallEventOncePerInstall() {
        let environment = harness.makeEnvironment(scope: .everyone)
        InstallCollector(environment: environment).start()
        InstallCollector(environment: environment).start()
        let events = environment.storedEvents()
        XCTAssertEqual(events.map(\.name), [.install])
        XCTAssertEqual(events.first?.properties["is_reinstall"], .bool(false))
        XCTAssertEqual(events.first?.properties["id_source"], "keychain")
    }

    func testInstallEventAfterReinstall() {
        let first = harness.makeEnvironment(scope: .everyone)
        InstallCollector(environment: first).start()
        _ = first.storedEvents()

        let reinstalled = TestHarness(keychain: harness.keychain)
        defer { reinstalled.tearDown() }
        let environment = reinstalled.makeEnvironment(scope: .everyone)
        InstallCollector(environment: environment).start()
        let events = environment.storedEvents()
        XCTAssertEqual(events.map(\.name), [.install])
        XCTAssertEqual(events.first?.properties["is_reinstall"], .bool(true))
        XCTAssertEqual(events.first?.installId, first.identity.installId)
    }
}

/// The real Keychain either round-trips or throws a `KeychainError`; it never crashes.
/// On macOS `swift test` and in a hostless simulator test bundle it usually throws -34018.
final class SystemKeychainTests: XCTestCase {
    func testRoundTripOrCleanError() {
        let keychain = SystemKeychain()
        let payload = Data(#"{"probe":true}"#.utf8)
        do {
            let before = try keychain.read()
            try keychain.write(payload)
            XCTAssertEqual(try keychain.read(), payload)
            // Put back whatever was there (normally nothing).
            if let before { try keychain.write(before) } else { deleteItem() }
            print("SystemKeychain: available")
        } catch let error as KeychainError {
            print("SystemKeychain: unavailable here, \(error)")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    private func deleteItem() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SystemKeychain.service,
            kSecAttrAccount as String: SystemKeychain.account,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        SecItemDelete(query as CFDictionary)
    }
}
