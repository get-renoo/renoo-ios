import Foundation

/// The two reads the SDK makes from the Events API: `GET /health-check` and `GET /offers`.
///
/// - On start-up: `GET /health-check` (no identity), then (unless it answered `401`) `GET /offers`.
/// - `GET /offers` is sent only while the user is tracked (the event pipeline's tracking gate:
///   active paid subscription or trial, or always with `trackingScope: .everyone`). Nothing about
///   a user outside the gate reaches the server, not even the anonymous ID header.
/// - When the app becomes active, and when the gate opens: `GET /offers`, at most once per
///   `offersInterval` after the last answered fetch (`200` or `204`). A failed fetch, or one
///   skipped because of the gate, does not count, so the next trigger retries.
/// - When the gate closes, an offers request in flight is dropped and the pending offer is cleared
///   (offers are only for current subscribers). The interval is kept.
/// - `401` from either call is the kill switch: `onUnauthorized` runs and nothing more is sent
///   until the next start-up.
///
/// All state lives on the SDK serial queue; requests never start on the main thread.
final class RemoteChecks: TrackingGateListener {
    struct Dependencies {
        var transport: UploadTransport
        var clock: UploadClock

        static func live(settings: UploadSettings) -> Dependencies {
            Dependencies(transport: URLSessionTransport(settings: settings), clock: SystemUploadClock())
        }
    }

    static let offersInterval: TimeInterval = 6 * 60 * 60
    static let anonymousIdHeader = "X-Renoo-Anonymous-Id"
    static let userIdHeader = "X-Renoo-User-Id"

    private let healthCheckURL: URL
    private let offersURL: URL
    private let apiKey: String
    private let pipeline: EventPipeline
    private let offers: PendingOfferStore
    private let queue: DispatchQueue
    private let logger: SDKLogger
    private let settings: UploadSettings
    private let deps: Dependencies

    /// Set once by `SDKCore` before `start()`. Called on the SDK queue.
    var onUnauthorized: (() -> Void)?

    // SDK queue only.
    private var started = false
    private(set) var isStopped = false
    private var healthCheck: UploadCancellable?
    private var offersRequest: UploadCancellable?
    /// When `GET /offers` last got an answer (`200` or `204`).
    private(set) var lastOffersAnswerAt: Date?
    /// Bumped by `identityReset()` and when the gate closes: an answer to an older request is ignored.
    private var generation = 0

    init(
        healthCheckURL: URL,
        offersURL: URL,
        apiKey: String,
        pipeline: EventPipeline,
        offers: PendingOfferStore,
        queue: DispatchQueue,
        logger: SDKLogger,
        settings: UploadSettings = .defaults,
        dependencies: Dependencies
    ) {
        self.healthCheckURL = healthCheckURL
        self.offersURL = offersURL
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pipeline = pipeline
        self.offers = offers
        self.queue = queue
        self.logger = logger
        self.settings = settings
        self.deps = dependencies
    }

    // MARK: Entry points

    /// Called once from `SDKCore.start()`.
    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            checkHealth()
        }
    }

    /// Main thread, from the lifecycle collector, each time the app becomes active.
    func appDidBecomeActive() {
        queue.async { [self] in
            // Until the health check has answered, start-up owns the first offers fetch.
            guard started, healthCheck == nil else { return }
            fetchOffersIfDue(trigger: "foreground")
        }
    }

    /// From the pipeline, on the SDK queue, when the user enters or leaves tracking scope.
    func trackingGateDidChange(isOpen: Bool) {
        guard !isStopped else { return }
        if isOpen {
            // Until the health check has answered, start-up owns the first offers fetch.
            guard started, healthCheck == nil else { return }
            fetchOffersIfDue(trigger: "tracking started")
        } else {
            generation += 1
            offersRequest?.cancel()
            offersRequest = nil
            offers.set(nil)
        }
    }

    /// Logout: the pending offer belonged to the previous user. It is cleared, an answer still in
    /// flight is ignored, and the next trigger fetches again without waiting for the interval.
    func identityReset() {
        queue.async { [self] in
            generation += 1
            offersRequest?.cancel()
            offersRequest = nil
            lastOffersAnswerAt = nil
            offers.set(nil)
        }
    }

    /// Kill switch or opt-out: cancel everything and forget the offer. SDK queue only.
    func stop() {
        isStopped = true
        healthCheck?.cancel()
        healthCheck = nil
        offersRequest?.cancel()
        offersRequest = nil
        offers.set(nil)
    }

    // MARK: Requests (SDK queue)

    private func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: settings.connectTimeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func checkHealth() {
        guard !isStopped else { return }
        healthCheck = deps.transport.send(makeRequest(healthCheckURL)) { [weak self] result in
            self?.queue.async { self?.handleHealth(result) }
        }
    }

    private func handleHealth(_ result: Result<HTTPResponse, Error>) {
        guard !isStopped, healthCheck != nil else { return }
        healthCheck = nil
        switch result {
        case .success(let response) where response.statusCode == 401:
            logger.error("health check answered 401 (API key unknown or blocked); the SDK stops until the next launch")
            unauthorized()
            return
        case .success(let response):
            // 200 carries on. Anything else (5xx, unexpected) also carries on: uploads will find out.
            if response.statusCode != 200 { logger.debug("health check answered \(response.statusCode); carrying on") }
        case .failure:
            logger.debug("health check failed (network); carrying on")
        }
        fetchOffersIfDue(trigger: "start-up")
    }

    /// Fetches unless the user is outside the gate or the last answer is newer than `offersInterval`.
    private func fetchOffersIfDue(trigger: String) {
        guard pipeline.isTracked else {
            logger.debug("offers not fetched (\(trigger)): user is not in tracking scope")
            return
        }
        if let last = lastOffersAnswerAt, deps.clock.now.timeIntervalSince(last) < Self.offersInterval {
            return
        }
        fetchOffers(trigger: trigger)
    }

    func makeOffersRequest() -> URLRequest {
        var request = makeRequest(offersURL)
        // Identity goes in headers, never in the URL (URLs end up in load-balancer logs).
        request.setValue(pipeline.anonymousId, forHTTPHeaderField: Self.anonymousIdHeader)
        if let userId = pipeline.currentUserId {
            request.setValue(userId, forHTTPHeaderField: Self.userIdHeader)
        }
        return request
    }

    private func fetchOffers(trigger: String) {
        guard !isStopped, offersRequest == nil else { return }
        guard !pipeline.isOptedOut, pipeline.isTracked else { return }
        logger.debug("fetching offers (\(trigger))")
        let requestGeneration = generation
        offersRequest = deps.transport.send(makeOffersRequest()) { [weak self] result in
            self?.queue.async { self?.handleOffers(result, generation: requestGeneration) }
        }
    }

    private func handleOffers(_ result: Result<HTTPResponse, Error>, generation: Int) {
        guard !isStopped, generation == self.generation, offersRequest != nil else { return }
        offersRequest = nil
        guard !pipeline.isOptedOut else { return }
        let response: HTTPResponse
        switch result {
        case .failure:
            logger.debug("offers fetch failed (network); will retry on the next trigger")
            return
        case .success(let value):
            response = value
        }
        switch response.statusCode {
        case 200:
            guard case .object(let json)? = try? JSONDecoder().decode(JSONValue.self, from: response.body) else {
                logger.error("offers answered 200 without a JSON object; ignored")
                return
            }
            lastOffersAnswerAt = deps.clock.now
            offers.set(PendingOffer(json: json))
            logger.debug("pending offer received")
        case 204:
            lastOffersAnswerAt = deps.clock.now
            offers.set(nil)
        case 401:
            logger.error("offers answered 401 (API key unknown or blocked); the SDK stops until the next launch")
            unauthorized()
        default:
            logger.debug("offers answered \(response.statusCode); will retry on the next trigger")
        }
    }

    private func unauthorized() {
        stop()
        onUnauthorized?()
    }

    // MARK: Test hooks

    var hasHealthCheckInFlight: Bool { healthCheck != nil }
    var hasOffersRequestInFlight: Bool { offersRequest != nil }
}
