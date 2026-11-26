import Foundation

/// Owns the pipeline and the collectors for one configured SDK.
final class SDKCore {
    static let defaultsSuiteName = "dev.renoo.sdk"

    let environment: SDKEnvironment
    let install: InstallCollector
    let context: ContextCollector
    let lifecycle: LifecycleCollector
    let screens: ScreenCollector
    let subscription: SubscriptionCollector
    /// Nil when `ingestURL` is nil or rejected: capture only, no network code runs.
    let uploader: EventUploader?
    /// `GET /health-check` and `GET /offers`. Nil exactly when `uploader` is nil.
    let remoteChecks: RemoteChecks?
    let pendingOffers = PendingOfferStore()

    /// - Parameters:
    ///   - uploadDependencies: for tests; called only when an uploader is created.
    ///   - remoteDependencies: for tests; called only when remote checks are created.
    init(
        configuration: Configuration,
        defaults: UserDefaults? = nil,
        storeDirectory: URL? = nil,
        uploadDependencies: ((UploadSettings) -> EventUploader.Dependencies)? = nil,
        remoteDependencies: ((UploadSettings) -> RemoteChecks.Dependencies)? = nil
    ) {
        let logger = SDKLogger(level: configuration.logLevel)
        let defaults = defaults ?? UserDefaults(suiteName: Self.defaultsSuiteName) ?? .standard
        let queue = DispatchQueue(label: "dev.renoo.sdk", qos: .utility)
        let identity = InstallIdentity(defaults: defaults, logger: logger)
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let pipeline = EventPipeline(
            queue: queue,
            storeProvider: {
                EventStore(directory: storeDirectory ?? EventStore.defaultDirectory(), logger: logger)
            },
            defaults: defaults,
            logger: logger,
            envelope: .init(
                sdkVersion: Renoo.sdkVersion,
                appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
                appBuild: info["CFBundleVersion"] as? String ?? "unknown",
                osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            ),
            trackingScope: configuration.trackingScope,
            installIdProvider: { identity.installId }
        )
        environment = SDKEnvironment(
            configuration: configuration,
            pipeline: pipeline,
            defaults: defaults,
            logger: logger,
            queue: queue,
            identity: identity
        )
        install = InstallCollector(environment: environment)
        context = ContextCollector(environment: environment)
        lifecycle = LifecycleCollector(environment: environment, context: context)
        screens = ScreenCollector(environment: environment)
        subscription = SubscriptionCollector(environment: environment)
        let urls = Self.validatedURLs(configuration: configuration, logger: logger)
        let settings = UploadSettings.defaults
        uploader = urls.map { urls in
            EventUploader(
                endpoint: urls.events,
                apiKey: configuration.apiKey,
                pipeline: pipeline,
                queue: queue,
                logger: logger,
                settings: settings,
                dependencies: (uploadDependencies ?? EventUploader.Dependencies.live)(settings)
            )
        }
        remoteChecks = urls.map { [pendingOffers] urls in
            RemoteChecks(
                healthCheckURL: urls.healthCheck,
                offersURL: urls.offers,
                apiKey: configuration.apiKey,
                pipeline: pipeline,
                offers: pendingOffers,
                queue: queue,
                logger: logger,
                settings: settings,
                dependencies: (remoteDependencies ?? RemoteChecks.Dependencies.live)(settings)
            )
        }
        pipeline.listener = uploader
        // `GET /offers` follows the same tracking gate as events.
        pipeline.trackingGateListener = remoteChecks
        // A 401 from any call is the kill switch. Both callbacks run on the SDK queue.
        let killSwitch = { [weak remoteChecks, weak pipeline] in
            remoteChecks?.stop()
            pipeline?.disable()
        }
        uploader?.onUnauthorized = killSwitch
        remoteChecks?.onUnauthorized = killSwitch
        if let uploader, let remoteChecks {
            lifecycle.onBecameActive = {
                uploader.appDidBecomeActive()
                remoteChecks.appDidBecomeActive()
            }
            lifecycle.onEnteredBackground = { uploader.appDidEnterBackground() }
        }
    }

    /// The Events API URLs, or nil for capture only (no `ingestURL`, or one that is rejected).
    private static func validatedURLs(configuration: Configuration, logger: SDKLogger) -> IngestEndpoint.URLs? {
        guard let base = configuration.ingestURL else { return nil }
        switch IngestEndpoint.urls(base: base, allowInsecureHTTP: configuration.allowInsecureHTTP) {
        case .failure(let problem):
            logger.error("\(problem). Uploading is disabled; events are still captured.")
            return nil
        case .success(let urls):
            if urls.events.scheme?.lowercased() == "http" {
                logger.error("allowInsecureHTTP is on and ingestURL uses http. Debug only: never ship this.")
            }
            return urls
        }
    }

    /// Logout. The pending offer belonged to the previous user.
    func identityReset() {
        if let remoteChecks {
            remoteChecks.identityReset()
        } else {
            pendingOffers.set(nil)
        }
    }

    /// Opt-out: forget the pending offer; no `GET /offers` is made while opted out.
    func optedOut() {
        pendingOffers.set(nil)
    }

    /// Main thread. Order matters: install and subscription state first, then lifecycle.
    func start() {
        install.start()
        uploader?.start()
        // Off the main thread: `start()` only queues the health check on the SDK queue.
        remoteChecks?.start()
        // After the uploader, so the first `identify` isn't mistaken for a leftover from the last run.
        environment.pipeline.start()
        subscription.start()
        context.start()
        lifecycle.start()
        screens.start()
        environment.logger.info("configured (sdk \(Renoo.sdkVersion))")
    }
}
