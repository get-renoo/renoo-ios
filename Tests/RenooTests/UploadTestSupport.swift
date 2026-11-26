import Foundation
@testable import Renoo

final class FakeCancellable: UploadCancellable {
    private(set) var cancelled = false
    private let onCancel: () -> Void
    init(onCancel: @escaping () -> Void = {}) { self.onCancel = onCancel }
    func cancel() {
        cancelled = true
        onCancel()
    }
}

/// Records requests; the test answers them one at a time.
final class FakeTransport: UploadTransport {
    struct Sent {
        let request: URLRequest
        let onMainThread: Bool
        let completion: (Result<HTTPResponse, Error>) -> Void
        let cancellable: FakeCancellable
    }

    private let lock = NSLock()
    private var _sent: [Sent] = []
    private var pending: [Sent] = []

    var sent: [Sent] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }
    var requests: [URLRequest] { sent.map(\.request) }
    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    func send(_ request: URLRequest, completion: @escaping (Result<HTTPResponse, Error>) -> Void) -> UploadCancellable {
        let cancellable = FakeCancellable()
        let item = Sent(request: request, onMainThread: Thread.isMainThread, completion: completion, cancellable: cancellable)
        lock.lock()
        _sent.append(item)
        pending.append(item)
        lock.unlock()
        return cancellable
    }

    /// Answers the oldest unanswered request.
    func respond(_ status: Int, headers: [String: String] = [:], body: String = "") {
        lock.lock()
        guard !pending.isEmpty else { lock.unlock(); return }
        let item = pending.removeFirst()
        lock.unlock()
        item.completion(.success(HTTPResponse(statusCode: status, headers: headers, body: Data(body.utf8))))
    }

    func fail(_ error: Error = URLError(.timedOut)) {
        lock.lock()
        guard !pending.isEmpty else { lock.unlock(); return }
        let item = pending.removeFirst()
        lock.unlock()
        item.completion(.failure(error))
    }
}

/// Manual time. Scheduled work runs on its queue when `advance` passes its due time.
final class FakeClock: UploadClock {
    private struct Item {
        let id: Int
        let due: Date
        let queue: DispatchQueue
        let work: () -> Void
        let handle: FakeCancellable
    }

    private let lock = NSLock()
    private var current: Date
    private var items: [Item] = []
    private var nextId = 0

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    var nextDue: Date? {
        lock.lock(); defer { lock.unlock() }
        return items.filter { !$0.handle.cancelled }.map(\.due).min()
    }

    func schedule(after delay: TimeInterval, on queue: DispatchQueue, _ work: @escaping () -> Void) -> UploadCancellable {
        lock.lock()
        defer { lock.unlock() }
        nextId += 1
        let handle = FakeCancellable()
        items.append(Item(id: nextId, due: current.addingTimeInterval(delay), queue: queue, work: work, handle: handle))
        return handle
    }

    /// Moves time forward, running due work in order (each on its queue, waited for).
    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while true {
            lock.lock()
            items.removeAll { $0.handle.cancelled }
            guard let next = items.filter({ $0.due <= target }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) else {
                current = target
                lock.unlock()
                return
            }
            items.removeAll { $0.id == next.id }
            current = next.due
            lock.unlock()
            next.queue.sync(execute: next.work)
        }
    }
}

final class FakeNetwork: NetworkStatusMonitor {
    private(set) var status: NetworkStatus
    private var onChange: ((NetworkStatus) -> Void)?
    private var queue: DispatchQueue?

    init(_ status: NetworkStatus = .other) { self.status = status }

    func start(queue: DispatchQueue, onChange: @escaping (NetworkStatus) -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    func set(_ status: NetworkStatus) {
        self.status = status
        queue?.sync { onChange?(status) }
    }
}

final class FakeBackgroundTasks: BackgroundTaskRunner {
    private(set) var begun = 0
    private(set) var ended = 0
    private var expirations: [() -> Void] = []
    var available = true

    func begin(name: String, expiration: @escaping () -> Void) -> BackgroundTaskHandle? {
        guard available else { return nil }
        begun += 1
        var handle: BackgroundTaskHandle?
        handle = BackgroundTaskHandle { [weak self] in self?.ended += 1 }
        expirations.append {
            expiration()
            handle?.end()
        }
        return handle
    }

    /// Simulates iOS running out of background time.
    func expireAll() {
        let all = expirations
        expirations.removeAll()
        all.forEach { $0() }
    }
}

/// A pipeline on a temp queue file plus an uploader with fake dependencies.
final class UploadHarness {
    let harness = TestHarness()
    let transport = FakeTransport()
    let clock = FakeClock()
    let network: FakeNetwork
    let backgroundTasks = FakeBackgroundTasks()
    let environment: SDKEnvironment
    var random: Double = 0.5
    private(set) var uploader: EventUploader!
    /// How many times the uploader reported a 401 (it then fires the kill switch, as in `SDKCore`).
    private(set) var unauthorizedCalls = 0
    var settings: UploadSettings
    let endpoint = URL(string: "https://ingest.example.com/events/sdk")!

    init(settings: UploadSettings = .defaults, network: NetworkStatus = .other) {
        self.settings = settings
        self.network = FakeNetwork(network)
        environment = harness.makeEnvironment(scope: .everyone)
        uploader = makeUploader()
    }

    var pipeline: EventPipeline { environment.pipeline }

    var dependencies: EventUploader.Dependencies {
        EventUploader.Dependencies(
            transport: transport,
            clock: clock,
            network: network,
            backgroundTasks: backgroundTasks,
            random: { [unowned self] in self.random }
        )
    }

    func makeUploader() -> EventUploader {
        let uploader = EventUploader(
            endpoint: endpoint,
            apiKey: "pk_test_secret",
            pipeline: environment.pipeline,
            queue: environment.queue,
            logger: harness.logger,
            settings: settings,
            dependencies: dependencies
        )
        environment.pipeline.listener = uploader
        let pipeline = environment.pipeline
        uploader.onUnauthorized = { [unowned self] in
            unauthorizedCalls += 1
            pipeline.disable()
        }
        return uploader
    }

    /// Simulates a cold start: a new uploader on the same disk queue.
    func relaunch() {
        uploader = makeUploader()
        start()
    }

    func start() {
        uploader.start()
        settle()
    }

    func track(_ count: Int, name: EventName = .screenView) {
        for _ in 0..<count { pipeline.track(name) }
        settle()
    }

    /// Waits for queued SDK work, including work that queues more work.
    func settle() {
        for _ in 0..<4 { environment.queue.sync {} }
    }

    func onQueue<T>(_ work: () -> T) -> T { environment.queue.sync(execute: work) }

    var queuedIds: [String] { pipeline.queuedEvents().map(\.eventId) }

    func respond(_ status: Int, headers: [String: String] = [:], body: String = "") {
        transport.respond(status, headers: headers, body: body)
        settle()
    }

    func fail(_ error: Error = URLError(.timedOut)) {
        transport.fail(error)
        settle()
    }

    func advance(_ seconds: TimeInterval) {
        clock.advance(by: seconds)
        settle()
    }

    func background() {
        uploader.appDidEnterBackground()
        settle()
    }

    func tearDown() { harness.tearDown() }
}

extension URLRequest {
    /// The gunzipped NDJSON body, one string per line.
    var ndjsonLines: [String] {
        guard let body = httpBody else { return [] }
        let raw = value(forHTTPHeaderField: "Content-Encoding") == "gzip" ? Gzip.decompress(body) : body
        guard let raw else { return [] }
        return String(decoding: raw, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    var eventIds: [String] {
        ndjsonLines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["event_id"] as? String
        }
    }

    var batchId: String? { value(forHTTPHeaderField: "X-Renoo-Batch-Id") }
    var sentAt: String? { value(forHTTPHeaderField: "X-Renoo-Sent-At") }
}
