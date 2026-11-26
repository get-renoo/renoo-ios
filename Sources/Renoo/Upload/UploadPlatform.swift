import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// Something that can be cancelled: an HTTP request or a scheduled block.
protocol UploadCancellable: AnyObject {
    func cancel()
}

// MARK: Transport

struct HTTPResponse {
    let statusCode: Int
    /// Header names lowercased.
    let headers: [String: String]
    let body: Data
}

/// Sends one request. `completion` is called exactly once, on any thread.
protocol UploadTransport: AnyObject {
    func send(_ request: URLRequest, completion: @escaping (Result<HTTPResponse, Error>) -> Void) -> UploadCancellable
}

/// `URLSession` with an ephemeral configuration, no cookies, no cache, default
/// transports only. Redirects are not followed (the 3xx comes back as the response), so the
/// API key never goes to another URL.
final class URLSessionTransport: NSObject, UploadTransport, URLSessionTaskDelegate {
    private let settings: UploadSettings
    private let protocolClasses: [AnyClass]?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        // URLSession has no separate connect timeout: the idle timeout (no bytes for 10 s) covers
        // the connect phase, the resource timeout caps the whole request at 30 s.
        configuration.timeoutIntervalForRequest = settings.connectTimeout
        configuration.timeoutIntervalForResource = settings.requestTimeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// - Parameter protocolClasses: tests only (a `URLProtocol` stub).
    init(settings: UploadSettings, protocolClasses: [AnyClass]? = nil) {
        self.settings = settings
        self.protocolClasses = protocolClasses
    }

    func send(_ request: URLRequest, completion: @escaping (Result<HTTPResponse, Error>) -> Void) -> UploadCancellable {
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String { headers[key.lowercased()] = "\(value)" }
            }
            completion(.success(HTTPResponse(statusCode: http.statusCode, headers: headers, body: data ?? Data())))
        }
        task.resume()
        return TaskHandle(task: task)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private final class TaskHandle: UploadCancellable {
        let task: URLSessionTask
        init(task: URLSessionTask) { self.task = task }
        func cancel() { task.cancel() }
    }
}

// MARK: Clock

/// Wall clock plus delayed work on the SDK queue. Faked in tests.
protocol UploadClock: AnyObject {
    var now: Date { get }
    /// Runs `work` on `queue` after `delay` seconds, unless cancelled.
    func schedule(after delay: TimeInterval, on queue: DispatchQueue, _ work: @escaping () -> Void) -> UploadCancellable
}

final class SystemUploadClock: UploadClock {
    var now: Date { Date() }

    func schedule(after delay: TimeInterval, on queue: DispatchQueue, _ work: @escaping () -> Void) -> UploadCancellable {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return WorkItemHandle(item: item)
    }

    private final class WorkItemHandle: UploadCancellable {
        let item: DispatchWorkItem
        init(item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }
}

// MARK: Network status

enum NetworkStatus: Equatable {
    /// No path update yet. Treated as online.
    case unknown
    case offline
    case cellular
    case other
}

/// Reports the device's network path. Callbacks arrive on the queue passed to `start`.
protocol NetworkStatusMonitor: AnyObject {
    var status: NetworkStatus { get }
    func start(queue: DispatchQueue, onChange: @escaping (NetworkStatus) -> Void)
}

/// `NWPathMonitor`: no permission, no traffic.
final class PathNetworkMonitor: NetworkStatusMonitor {
    private let lock = NSLock()
    private var current = NetworkStatus.unknown
    private var monitor: NWPathMonitor?

    var status: NetworkStatus {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func start(queue: DispatchQueue, onChange: @escaping (NetworkStatus) -> Void) {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let status: NetworkStatus
            if path.status != .satisfied {
                status = .offline
            } else if path.usesInterfaceType(.cellular) {
                status = .cellular
            } else {
                status = .other
            }
            self?.lock.lock()
            self?.current = status
            self?.lock.unlock()
            onChange(status)
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    deinit { monitor?.cancel() }
}

// MARK: Background time

/// iOS background task assertion. `end()` is idempotent and safe from any thread.
final class BackgroundTaskHandle {
    private let lock = NSLock()
    private var endAction: (() -> Void)?

    init(end: @escaping () -> Void) { endAction = end }

    func end() {
        lock.lock()
        let action = endAction
        endAction = nil
        lock.unlock()
        action?()
    }
}

protocol BackgroundTaskRunner: AnyObject {
    /// Main thread. Returns nil where background time is not available.
    func begin(name: String, expiration: @escaping () -> Void) -> BackgroundTaskHandle?
}

final class SystemBackgroundTaskRunner: BackgroundTaskRunner {
    func begin(name: String, expiration: @escaping () -> Void) -> BackgroundTaskHandle? {
        #if canImport(UIKit) && !os(watchOS)
        guard let app = HostApplication.shared else { return nil }
        var identifier = UIBackgroundTaskIdentifier.invalid
        var handle: BackgroundTaskHandle?
        identifier = app.beginBackgroundTask(withName: name) {
            // Main thread. Stop the flush, then end the task before returning.
            expiration()
            handle?.end()
        }
        guard identifier != .invalid else { return nil }
        let created = BackgroundTaskHandle {
            let end = { app.endBackgroundTask(identifier) }
            if Thread.isMainThread { end() } else { DispatchQueue.main.async(execute: end) }
        }
        handle = created
        return created
        #else
        return nil
        #endif
    }
}
