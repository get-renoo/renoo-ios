import XCTest
@testable import Renoo

/// The uploader inside a real `SDKCore`: configuration rules and lifecycle triggers.
final class UploadWiringTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let transport = FakeTransport()
    private let clock = FakeClock()
    private var factoryCalls = 0

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        factoryCalls = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeCore(url: String?, insecure: Bool = false) -> SDKCore {
        var configuration = Configuration(apiKey: "pk_test", purchaseHandler: { _ in .cancelled })
        configuration.trackingScope = .everyone
        configuration.logLevel = .none
        configuration.automaticScreenTracking = false
        configuration.ingestURL = url.flatMap(URL.init(string:))
        configuration.allowInsecureHTTP = insecure
        return SDKCore(
            configuration: configuration,
            defaults: defaults,
            storeDirectory: directory,
            uploadDependencies: { [self] _ in
                factoryCalls += 1
                return EventUploader.Dependencies(
                    transport: transport, clock: clock, network: FakeNetwork(),
                    backgroundTasks: FakeBackgroundTasks(), random: { 0.5 }
                )
            },
            // Health check and offers go to their own fake, so `transport` sees uploads only.
            remoteDependencies: { [clock] _ in RemoteChecks.Dependencies(transport: FakeTransport(), clock: clock) }
        )
    }

    private func settle(_ core: SDKCore) {
        for _ in 0..<4 { core.environment.queue.sync {} }
    }

    func testNilURLCreatesNoUploaderAndSendsNothing() {
        let core = makeCore(url: nil)
        XCTAssertNil(core.uploader)
        core.lifecycle.becameActive()
        for _ in 0..<150 { core.screens.trackScreen(name: "Home", source: .manual) }
        core.lifecycle.enteredBackground()
        settle(core)
        XCTAssertEqual(factoryCalls, 0, "no network code created")
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertGreaterThan(core.environment.pipeline.queuedEvents().count, 150, "capture continues")
    }

    func testHTTPURLDisablesUploadingButCaptureContinues() {
        let core = makeCore(url: "http://localhost:8787")
        XCTAssertNil(core.uploader)
        XCTAssertEqual(factoryCalls, 0)
        core.lifecycle.becameActive()
        settle(core)
        XCTAssertFalse(core.environment.pipeline.queuedEvents().isEmpty)
    }

    func testHTTPURLIsAcceptedWithTheDebugFlag() {
        let core = makeCore(url: "http://localhost:8787/", insecure: true)
        XCTAssertNotNil(core.uploader)
        core.start()
        core.lifecycle.becameActive()
        core.lifecycle.enteredBackground()
        settle(core)
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "http://localhost:8787/events/sdk")
    }

    func testBackgroundFlushIncludesTheAppBackgroundEvent() throws {
        let core = makeCore(url: "https://ingest.example.com")
        core.start()
        core.lifecycle.becameActive()
        core.screens.trackScreen(name: "Home", source: .manual)
        core.lifecycle.enteredBackground()
        settle(core)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pk_test")
        let names = request.ndjsonLines.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["name"] as? String
        }
        XCTAssertEqual(names.last, "app_background")
        // On iOS the StoreKit collector may add an event after the batch was cut; it stays queued.
        let sent = Set(request.eventIds)
        XCTAssertTrue(sent.isSubset(of: Set(core.environment.pipeline.queuedEvents().map(\.eventId))))
        transport.respond(202)
        settle(core)
        XCTAssertTrue(Set(core.environment.pipeline.queuedEvents().map(\.eventId)).isDisjoint(with: sent))
    }

    func testBecomingActiveStartsTheForegroundTimer() {
        let core = makeCore(url: "https://ingest.example.com")
        core.start()
        core.lifecycle.becameActive()
        settle(core)
        XCTAssertTrue(transport.requests.isEmpty)
        clock.advance(by: 300)
        settle(core)
        XCTAssertEqual(transport.requests.count, 1)
    }
}

final class EventStoreUploadTests: XCTestCase {
    private var directory: URL!
    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func event(_ id: String) -> Event {
        Event(eventId: id, name: .appOpen, timestamp: "2026-11-16T00:00:00.000Z", seq: 1, installId: "i", anonymousId: "a",
              userId: nil, sessionId: nil, schemaVersion: 0, sdkVersion: "0", platform: "ios",
              appVersion: "1", appBuild: "1", osVersion: "26", properties: [:])
    }

    func testOldestRespectsCountAndBytesAndRemoveDeletesById() throws {
        let store = EventStore(directory: directory, logger: SDKLogger(level: .none))
        ["a", "b", "c", "d"].forEach { store.append(event($0)) }
        XCTAssertEqual(store.oldest(maxEvents: 2, maxBytes: .max).map(\.eventId), ["a", "b"])
        XCTAssertEqual(store.oldest(maxEvents: 10, maxBytes: 1).map(\.eventId), ["a"], "always at least one")
        XCTAssertEqual(store.oldest(maxEvents: 1, maxBytes: .max).first?.data, event("a").jsonData())
        store.remove(eventIds: ["a", "c"])
        XCTAssertEqual(store.all().map(\.eventId), ["b", "d"])
        XCTAssertEqual(store.count, 2)
        store.remove(eventIds: ["b", "d"])
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(store.all().isEmpty)
        store.append(event("e"))
        XCTAssertEqual(store.all().map(\.eventId), ["e"])
    }

    func testUnreadableLinesAreSkippedAndCleanedUp() throws {
        let store = EventStore(directory: directory, logger: SDKLogger(level: .none))
        store.append(event("a"))
        let file = directory.appendingPathComponent("queue.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"broken\n".utf8))
        try handle.close()
        store.append(event("b"))
        XCTAssertEqual(store.oldest(maxEvents: 10, maxBytes: .max).map(\.eventId), ["a", "b"])
        store.remove(eventIds: ["a"])
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 1)
    }
}

/// The real `URLSessionTransport` against a `URLProtocol` stub (no server).
final class URLSessionTransportTests: XCTestCase {
    final class Stub: URLProtocol {
        static var lastRequest: URLRequest?
        static var lastBody: Data?
        static var status = 202
        static var headers: [String: String] = [:]
        static var redirectTo: URL?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Stub.lastRequest = request
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                stream.close()
                Stub.lastBody = data
            } else {
                Stub.lastBody = request.httpBody
            }
            if let target = Stub.redirectTo {
                let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": target.absoluteString])!
                Stub.redirectTo = nil
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                // Refused by the delegate: the 3xx is the final response (as with the real HTTP stack).
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: Stub.status, httpVersion: "HTTP/1.1",
                                           headerFields: Stub.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"accepted":1,"rejected":[]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func send(_ transport: URLSessionTransport, _ request: URLRequest) -> Result<HTTPResponse, Error> {
        let done = expectation(description: "response")
        var result: Result<HTTPResponse, Error>?
        _ = transport.send(request) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return result ?? .failure(URLError(.timedOut))
    }

    func testSendsHeadersAndBodyAndReadsStatusAndHeaders() throws {
        Stub.status = 429
        Stub.headers = ["Retry-After": "120"]
        let transport = URLSessionTransport(settings: .defaults, protocolClasses: [Stub.self])
        var request = URLRequest(url: URL(string: "https://ingest.example.com/events/sdk")!)
        request.httpMethod = "POST"
        request.setValue("Bearer pk", forHTTPHeaderField: "Authorization")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.httpBody = Data("abc".utf8)
        let response = try send(transport, request).get()
        XCTAssertEqual(response.statusCode, 429)
        XCTAssertEqual(response.headers["retry-after"], "120")
        XCTAssertEqual(Stub.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer pk")
        XCTAssertEqual(Stub.lastRequest?.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(Stub.lastBody, Data("abc".utf8))
    }

    func testRedirectsAreNotFollowed() throws {
        Stub.status = 202
        Stub.headers = [:]
        Stub.redirectTo = URL(string: "https://elsewhere.example.com/collect")!
        let transport = URLSessionTransport(settings: .defaults, protocolClasses: [Stub.self])
        var request = URLRequest(url: URL(string: "https://ingest.example.com/events/sdk")!)
        request.httpMethod = "POST"
        request.httpBody = Data("abc".utf8)
        let response = try send(transport, request).get()
        XCTAssertEqual(response.statusCode, 307)
        XCTAssertEqual(Stub.lastRequest?.url?.host, "ingest.example.com", "no request to the redirect target")
    }
}
