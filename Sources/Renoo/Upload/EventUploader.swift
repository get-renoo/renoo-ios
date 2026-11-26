import Foundation

/// Why a flush was asked for. Shown in debug logs.
enum FlushTrigger: String {
    case coldStart = "cold_start"
    case background
    case threshold
    case foregroundTimer = "timer"
    case retry
    case networkBack = "network_back"
}

/// Sends the on-disk queue to the events API.
///
/// All state lives on the SDK serial queue (`environment.queue`), the same queue that writes the
/// disk queue, so a send never races an append. At most one request is in flight.
/// Events leave the disk only once the API has answered for them (accepted or permanently rejected); a kill mid-request leaves them queued
/// and they are sent again later (the backend dedupes by `event_id`).
///
/// A flush sends batches back to back until the events that were queued when it started are gone,
/// or until an answer that says "wait" (5xx, 429, network error, no network) or stop (401).
final class EventUploader: EventPipelineListener {
    struct Dependencies {
        var transport: UploadTransport
        var clock: UploadClock
        var network: NetworkStatusMonitor
        var backgroundTasks: BackgroundTaskRunner
        /// Uniform in [0, 1). Injected so tests are deterministic.
        var random: () -> Double

        static func live(settings: UploadSettings) -> Dependencies {
            Dependencies(
                transport: URLSessionTransport(settings: settings),
                clock: SystemUploadClock(),
                network: PathNetworkMonitor(),
                backgroundTasks: SystemBackgroundTaskRunner(),
                random: { Double.random(in: 0..<1) }
            )
        }
    }

    /// One cut of the queue. Its ID is reused for every retry, so the backend can spot a resend.
    struct Batch {
        let id: String
        let lines: [EventStore.StoredLine]
        let body: Data
        let isGzipped: Bool
        var eventIds: Set<String> { Set(lines.map(\.eventId)) }
    }

    private struct InFlight {
        let attempt: Int
        let batch: Batch
        let startedAt: Date
        let cancellable: UploadCancellable
    }

    private let endpoint: URL
    private let apiKey: String
    private let pipeline: EventPipeline
    private let queue: DispatchQueue
    private let logger: SDKLogger
    private let deps: Dependencies
    private(set) var settings: UploadSettings

    // SDK queue only.
    private var inFlight: InFlight?
    private var attemptCounter = 0
    /// A batch waiting to be retried as is.
    private var retryBatch: Batch?
    /// Halves from a 413 (or an oversize gzip body), sent before anything new is cut.
    private var splitBatches: [Batch] = []
    /// Events still to send in the current flush.
    private var flushBudget = 0
    private var consecutiveFailures = 0
    private var nextAttemptAt: Date?
    private var retryTimer: UploadCancellable?
    private var foregroundTimer: UploadCancellable?
    /// After a 401 (the kill switch) nothing is sent until the next cold start.
    private(set) var isStopped = false
    /// Set once by `SDKCore` before `start()`. Called on the SDK queue after a 401.
    var onUnauthorized: (() -> Void)?
    private var waitingForNetwork = false
    private var backgroundTasks: [BackgroundTaskHandle] = []
    private var started = false

    init(
        endpoint: URL,
        apiKey: String,
        pipeline: EventPipeline,
        queue: DispatchQueue,
        logger: SDKLogger,
        settings: UploadSettings = .defaults,
        dependencies: Dependencies
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pipeline = pipeline
        self.queue = queue
        self.logger = logger
        self.settings = settings
        self.deps = dependencies
    }

    // MARK: Entry points

    /// Called once from `SDKCore.start()`. Cold-start trigger.
    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            deps.network.start(queue: queue) { [weak self] status in self?.networkChanged(status) }
            logger.info("uploading to \(endpoint.absoluteString)")
            if pipeline.storedCount > 0 { requestFlush(.coldStart) }
        }
    }

    /// Remote config hook (server-set tunables). Not called yet.
    func update(settings: UploadSettings) {
        queue.async { [self] in self.settings = settings }
    }

    /// Main thread, from the lifecycle collector, after the app became active.
    func appDidBecomeActive() {
        queue.async { [self] in startForegroundTimer() }
    }

    /// Main thread, from the lifecycle collector, after `app_background` was tracked (so it is on
    /// disk before this flush runs: both go through the same serial queue, in this order).
    func appDidEnterBackground() {
        var handle: BackgroundTaskHandle?
        handle = deps.backgroundTasks.begin(name: "Renoo.upload") { [weak self] in
            self?.queue.async { self?.backgroundTimeExpired() }
        }
        queue.async { [self] in
            stopForegroundTimer()
            if let handle { backgroundTasks.append(handle) }
            requestFlush(.background)
            endBackgroundTasksIfIdle()
        }
    }

    // MARK: EventPipelineListener (SDK queue)

    func pipelineDidStore(queueCount: Int) {
        guard started, queueCount >= settings.flushThreshold else { return }
        requestFlush(.threshold)
    }

    func pipelineDidOptOut() {
        dropPendingWork()
    }

    func pipelineDidDisable() {
        stopUploading()
    }

    private func dropPendingWork() {
        inFlight?.cancellable.cancel()
        inFlight = nil
        retryBatch = nil
        splitBatches.removeAll()
        flushBudget = 0
        waitingForNetwork = false
        endBackgroundTasksIfIdle()
    }

    // MARK: Flushing (SDK queue)

    func requestFlush(_ trigger: FlushTrigger) {
        guard !isStopped, !pipeline.isOptedOut else { return }
        let count = pipeline.storedCount
        if trigger == .foregroundTimer, deps.network.status == .cellular, count < settings.cellularMinimumEvents {
            logger.debug("flush skipped (timer on cellular, \(count) events)")
            return
        }
        flushBudget = max(flushBudget, count)
        guard flushBudget > 0 || retryBatch != nil || !splitBatches.isEmpty else { return }
        logger.debug("flush requested (\(trigger.rawValue), \(count) queued)")
        pump()
    }

    /// Sends the next batch if nothing is in flight and nothing says wait.
    private func pump() {
        guard inFlight == nil else { return }
        guard !isStopped, !pipeline.isOptedOut else { return idle() }
        if let next = nextAttemptAt, deps.clock.now < next {
            scheduleRetry(at: next)
            return idle()
        }
        nextAttemptAt = nil
        if deps.network.status == .offline {
            waitingForNetwork = true
            logger.debug("flush waiting: no network")
            return idle()
        }
        guard let batch = nextBatch() else {
            flushBudget = 0
            return idle()
        }
        send(batch)
    }

    private func nextBatch() -> Batch? {
        if let retryBatch { return retryBatch }
        if !splitBatches.isEmpty { return splitBatches.removeFirst() }
        guard flushBudget > 0 else { return nil }
        let lines = pipeline.oldestStored(maxEvents: settings.maxEventsPerBatch, maxBytes: settings.maxDecompressedBytes)
        guard !lines.isEmpty else { return nil }
        var batch = makeBatch(lines)
        // Keep under the compressed limit on the device instead of earning a 413.
        while batch.body.count > settings.maxCompressedBytes, batch.lines.count > 1 {
            let halves = split(batch)
            splitBatches.insert(halves.1, at: 0)
            batch = halves.0
        }
        return batch
    }

    func makeBatch(_ lines: [EventStore.StoredLine]) -> Batch {
        var raw = Data()
        for line in lines {
            raw.append(line.data)
            raw.append(0x0A)
        }
        let gzipped = Gzip.compress(raw)
        return Batch(
            id: UUID().uuidString.lowercased(),
            lines: lines,
            body: gzipped ?? raw,
            isGzipped: gzipped != nil
        )
    }

    private func split(_ batch: Batch) -> (Batch, Batch) {
        let middle = batch.lines.count / 2
        return (makeBatch(Array(batch.lines[..<middle])), makeBatch(Array(batch.lines[middle...])))
    }

    func makeRequest(for batch: Batch, sentAt: Date) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: settings.connectTimeout)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        if batch.isGzipped { request.setValue("gzip", forHTTPHeaderField: "Content-Encoding") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Timestamp.string(from: sentAt), forHTTPHeaderField: "X-Renoo-Sent-At")
        request.setValue(batch.id, forHTTPHeaderField: "X-Renoo-Batch-Id")
        request.httpBody = batch.body
        return request
    }

    private func send(_ batch: Batch) {
        retryBatch = batch
        attemptCounter += 1
        let attempt = attemptCounter
        let now = deps.clock.now
        let request = makeRequest(for: batch, sentAt: now)
        let cancellable = deps.transport.send(request) { [weak self] result in
            self?.queue.async { self?.handle(result, attempt: attempt) }
        }
        inFlight = InFlight(attempt: attempt, batch: batch, startedAt: now, cancellable: cancellable)
    }

    private func handle(_ result: Result<HTTPResponse, Error>, attempt: Int) {
        // A request cancelled by opt-out or expiry, then answered late, is ignored.
        guard let flight = inFlight, flight.attempt == attempt else { return }
        inFlight = nil
        let batch = flight.batch
        let latency = Int(deps.clock.now.timeIntervalSince(flight.startedAt) * 1000)
        let summary = "batch \(batch.id), \(batch.lines.count) events, \(batch.body.count) bytes, \(latency) ms"

        guard !pipeline.isOptedOut else {
            retryBatch = nil
            return idle()
        }

        let response: HTTPResponse
        switch result {
        case .failure(let error):
            logger.debug("flush failed: \(Self.describe(error)) (\(summary))")
            return transientFailure()
        case .success(let value):
            response = value
        }
        logger.debug("flush status \(response.statusCode) (\(summary))")

        switch response.statusCode {
        case 202:
            logRejected(response.body)
            delivered(batch)
            consecutiveFailures = 0
            nextAttemptAt = nil
            pump()
        case 400:
            logger.error("events API answered 400 (body unreadable); deleted \(batch.lines.count) events")
            delivered(batch)
            pump()
        case 401:
            // The kill switch: the SDK stops capturing and drops the queue until the next launch.
            logger.error("events API answered 401 (API key unknown or blocked); the SDK stops until the next launch")
            stopUploading()
            onUnauthorized?()
        case 413:
            retryBatch = nil
            if batch.lines.count > 1 {
                let halves = split(batch)
                splitBatches.insert(contentsOf: [halves.0, halves.1], at: 0)
                logger.debug("413: split into \(halves.0.lines.count) + \(halves.1.lines.count)")
            } else {
                logger.error("events API answered 413 for a single event (\(batch.body.count) bytes); deleted it")
                delivered(batch)
            }
            pump()
        case 429:
            if let seconds = Self.retryAfterSeconds(response.headers["retry-after"]) {
                let delay = min(seconds, settings.backoffCap)
                nextAttemptAt = deps.clock.now.addingTimeInterval(delay)
                logger.debug("429: retrying in \(Int(delay)) s")
                scheduleRetry(at: nextAttemptAt)
                idle()
            } else {
                transientFailure()
            }
        case 500...599:
            transientFailure()
        default:
            logger.error("events API answered unexpected status \(response.statusCode); will retry")
            transientFailure()
        }
    }

    /// Events leave the disk queue (202, 400, single-event 413).
    private func delivered(_ batch: Batch) {
        retryBatch = nil
        pipeline.removeStored(eventIds: batch.eventIds)
        flushBudget = max(0, flushBudget - batch.lines.count)
    }

    /// 5xx, timeout, network error, unexpected status: keep the batch and back off exponentially.
    private func transientFailure() {
        consecutiveFailures += 1
        let delay = Self.backoffDelay(failures: consecutiveFailures, settings: settings, random: deps.random())
        nextAttemptAt = deps.clock.now.addingTimeInterval(delay)
        logger.debug("backing off \(Int(delay)) s (failure \(consecutiveFailures))")
        scheduleRetry(at: nextAttemptAt)
        idle()
    }

    /// Exponential with jitter: step = min(cap, base × factor^(n−1)), delay uniform in [step/2, step].
    /// Full jitter ([0, step]) could draw ~0 every time and break the rule of at most 12 attempts
    /// in the first hour of a lasting outage. Half-step floor: at most 8 attempts in that hour.
    static func backoffDelay(failures: Int, settings: UploadSettings, random: Double) -> TimeInterval {
        let exponent = Double(max(0, failures - 1))
        let step = min(settings.backoffCap, settings.backoffBase * pow(settings.backoffFactor, exponent))
        let unit = min(max(random, 0), 1)
        return step / 2 + unit * step / 2
    }

    /// Integer (or decimal) seconds. HTTP dates are not supported (the API sends seconds).
    static func retryAfterSeconds(_ value: String?) -> TimeInterval? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), let seconds = Double(text),
              seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private func scheduleRetry(at date: Date?) {
        guard let date else { return }
        retryTimer?.cancel()
        let delay = max(0, date.timeIntervalSince(deps.clock.now))
        retryTimer = deps.clock.schedule(after: delay, on: queue) { [weak self] in
            guard let self else { return }
            self.retryTimer = nil
            guard self.retryBatch != nil || !self.splitBatches.isEmpty || self.flushBudget > 0 else { return }
            self.logger.debug("flush requested (\(FlushTrigger.retry.rawValue))")
            self.pump()
        }
    }

    private func networkChanged(_ status: NetworkStatus) {
        guard status != .offline, waitingForNetwork else { return }
        waitingForNetwork = false
        logger.debug("flush requested (\(FlushTrigger.networkBack.rawValue))")
        pump()
    }

    private func backgroundTimeExpired() {
        // Background time ran out: the flush is cut short and retried at the next trigger, same batch.
        if let flight = inFlight {
            flight.cancellable.cancel()
            inFlight = nil
            logger.debug("background time expired; batch \(flight.batch.id) kept for the next flush")
        }
        backgroundTasks.removeAll()
    }

    private func idle() {
        endBackgroundTasksIfIdle()
    }

    private func endBackgroundTasksIfIdle() {
        guard inFlight == nil else { return }
        let tasks = backgroundTasks
        backgroundTasks.removeAll()
        tasks.forEach { $0.end() }
    }

    /// Kill switch: nothing more is sent until the next cold start. SDK queue only.
    private func stopUploading() {
        isStopped = true
        retryTimer?.cancel()
        retryTimer = nil
        nextAttemptAt = nil
        stopForegroundTimer()
        dropPendingWork()
    }

    // MARK: Foreground timer (SDK queue)

    private func startForegroundTimer() {
        guard foregroundTimer == nil, !isStopped else { return }
        let interval = settings.foregroundFlushInterval
        foregroundTimer = deps.clock.schedule(after: interval, on: queue) { [weak self] in
            guard let self else { return }
            self.foregroundTimer = nil
            if self.pipeline.storedCount > 0 { self.requestFlush(.foregroundTimer) }
            self.startForegroundTimer()
        }
    }

    private func stopForegroundTimer() {
        foregroundTimer?.cancel()
        foregroundTimer = nil
    }

    // MARK: Logging helpers

    private func logRejected(_ body: Data) {
        struct Accepted: Decodable {
            struct Rejection: Decodable { let event_id: String; let reason: String }
            let accepted: Int?
            let rejected: [Rejection]?
        }
        guard let parsed = try? JSONDecoder().decode(Accepted.self, from: body),
              let rejected = parsed.rejected, !rejected.isEmpty else { return }
        let reasons = Dictionary(grouping: rejected, by: \.reason).map { "\($0.key): \($0.value.count)" }.sorted()
        logger.error("events API rejected \(rejected.count) events (\(reasons.joined(separator: ", "))); deleted")
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError { return "URLError \(urlError.code.rawValue)" }
        return "\(type(of: error))"
    }

    // MARK: Test hooks

    var hasRequestInFlight: Bool { inFlight != nil }
    var scheduledNextAttempt: Date? { nextAttemptAt }
    var heldBackgroundTasks: Int { backgroundTasks.count }
}
