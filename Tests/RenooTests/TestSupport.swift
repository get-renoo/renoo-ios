import Foundation
@testable import Renoo

/// In-memory Keychain. `failure` makes every call throw, like error -34018 without a host app.
final class InMemoryKeychain: KeychainStore {
    var data: Data?
    var failure: OSStatus?
    private(set) var reads = 0
    private(set) var writes = 0

    func read() throws -> Data? {
        reads += 1
        if let failure { throw KeychainError(status: failure) }
        return data
    }

    func write(_ data: Data) throws {
        writes += 1
        if let failure { throw KeychainError(status: failure) }
        self.data = data
    }
}

/// A fresh UserDefaults suite, temp queue directory and SDK environment for one test.
final class TestHarness {
    let suiteName = "test.\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keychain: InMemoryKeychain
    let logger = SDKLogger(level: .none)

    init(keychain: InMemoryKeychain = InMemoryKeychain(), defaultsSuite: String? = nil) {
        self.keychain = keychain
        defaults = UserDefaults(suiteName: defaultsSuite ?? suiteName)!
    }

    func makeEnvironment(scope: Configuration.TrackingScope = .subscribersOnly) -> SDKEnvironment {
        var configuration = Configuration(apiKey: "test", purchaseHandler: { _ in .cancelled })
        configuration.trackingScope = scope
        let identity = InstallIdentity(defaults: defaults, logger: logger, keychain: keychain)
        let queue = DispatchQueue(label: "test.sdk")
        let directory = directory
        let logger = logger
        let pipeline = EventPipeline(
            queue: queue,
            storeProvider: { EventStore(directory: directory, logger: logger) },
            defaults: defaults,
            logger: logger,
            envelope: .init(sdkVersion: "0.0.0", appVersion: "1.0", appBuild: "1", osVersion: "26.0.0"),
            trackingScope: scope,
            installIdProvider: { identity.installId }
        )
        return SDKEnvironment(
            configuration: configuration,
            pipeline: pipeline,
            defaults: defaults,
            logger: logger,
            queue: queue,
            identity: identity
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

extension SDKEnvironment {
    /// Waits for queued work (including work that enqueues more work) and returns the stored events.
    func storedEvents() -> [Event] {
        queue.sync {}
        queue.sync {}
        return pipeline.queuedEvents()
    }
}
