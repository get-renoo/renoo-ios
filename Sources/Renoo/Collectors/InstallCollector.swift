import Foundation

/// Emits `install` once per install: on the first launch after an install or reinstall.
///
/// "Once per install" is a flag in the SDK's UserDefaults, which an uninstall wipes and the
/// Keychain does not. The Keychain work (resolving the identity) happens on the SDK queue.
final class InstallCollector: Collector {
    static let installTrackedKey = "install_event_tracked"

    private let environment: SDKEnvironment

    init(environment: SDKEnvironment) { self.environment = environment }

    func start() {
        let environment = environment
        environment.queue.async {
            let isReinstall = environment.identity.isReinstall
            let idSource = environment.identity.idSource
            guard !environment.defaults.bool(forKey: Self.installTrackedKey) else { return }
            environment.defaults.set(true, forKey: Self.installTrackedKey)
            environment.pipeline.track(.install, properties: [
                "is_reinstall": .bool(isReinstall),
                "id_source": .string(idSource.rawValue),
            ])
        }
    }
}
