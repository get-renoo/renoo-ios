import Foundation

/// Everything a collector needs. One instance per configured SDK.
final class SDKEnvironment: @unchecked Sendable {
    let configuration: Configuration
    let pipeline: EventPipeline
    /// The SDK's own UserDefaults suite. The only required-reason API the SDK uses.
    let defaults: UserDefaults
    let logger: SDKLogger
    /// The SDK's serial queue. Do disk, Keychain and StoreKit work here, never on the main thread.
    let queue: DispatchQueue
    let identity: InstallIdentity

    init(
        configuration: Configuration,
        pipeline: EventPipeline,
        defaults: UserDefaults,
        logger: SDKLogger,
        queue: DispatchQueue,
        identity: InstallIdentity
    ) {
        self.configuration = configuration
        self.pipeline = pipeline
        self.defaults = defaults
        self.logger = logger
        self.queue = queue
        self.identity = identity
    }
}

/// A source of events. `start()` is called once, on the main thread, from `configure`.
/// It must return quickly: hop to `environment.queue` for anything slow.
protocol Collector: AnyObject {
    func start()
}
