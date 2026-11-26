import XCTest
@testable import Renoo

final class EventUploaderTests: XCTestCase {
    private var h: UploadHarness!

    override func setUp() {
        super.setUp()
        h = UploadHarness()
    }

    override func tearDown() {
        h.tearDown()
        h = nil
        super.tearDown()
    }

    private func use(_ settings: UploadSettings, network: NetworkStatus = .other) {
        h.tearDown()
        h = UploadHarness(settings: settings, network: network)
    }

    // MARK: Request format

    func testRequestHeadersAuthAndGzipNDJSONBody() throws {
        h.start()
        h.track(3)
        let stored = h.pipeline.queuedEvents()
        h.background()

        let request = try XCTUnwrap(h.transport.requests.first)
        XCTAssertEqual(request.url, h.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pk_test_secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-ndjson")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(request.sentAt, Timestamp.string(from: h.clock.now))
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(request.batchId)))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))

        // Body: gzip of one stored JSON line per event, oldest first, newline-terminated.
        let raw = try XCTUnwrap(Gzip.decompress(try XCTUnwrap(request.httpBody)))
        XCTAssertEqual(String(decoding: raw, as: UTF8.self), stored.map { $0.jsonString() + "\n" }.joined())
        let decoded = try request.ndjsonLines.map { try JSONDecoder().decode(Event.self, from: Data($0.utf8)) }
        XCTAssertEqual(decoded, stored)
    }

    func testRequestsAreNeverMadeOnTheMainThread() {
        XCTAssertTrue(Thread.isMainThread)
        h.start()
        h.track(2)
        h.background()
        XCTAssertEqual(h.transport.sent.count, 1)
        XCTAssertFalse(h.transport.sent.allSatisfy(\.onMainThread))
    }

    // MARK: Batching

    func testBatchIsCutAt500AndTheQueueDrains() {
        var settings = UploadSettings.defaults
        settings.flushThreshold = 10_000 // isolate the background trigger
        use(settings)
        h.start()
        h.track(620)
        let all = h.queuedIds
        h.background()

        XCTAssertEqual(h.transport.requests.count, 1, "one request in flight")
        XCTAssertEqual(h.transport.requests[0].eventIds, Array(all.prefix(500)))
        h.respond(202, body: #"{"accepted":500,"rejected":[]}"#)

        XCTAssertEqual(h.transport.requests.count, 2)
        XCTAssertEqual(h.transport.requests[1].eventIds, Array(all.suffix(120)))
        XCTAssertNotEqual(h.transport.requests[0].batchId, h.transport.requests[1].batchId)
        h.respond(202, body: #"{"accepted":120,"rejected":[]}"#)

        XCTAssertTrue(h.queuedIds.isEmpty)
        XCTAssertEqual(h.transport.requests.count, 2)
    }

    func testEventsAppendedDuringARequestWaitForTheNextBatch() {
        h.start()
        h.track(5)
        let first = h.queuedIds
        h.background()
        h.track(2)
        XCTAssertEqual(h.transport.requests.count, 1)
        XCTAssertEqual(h.transport.requests[0].eventIds, first)
        h.respond(202)
        XCTAssertEqual(h.queuedIds.count, 2, "only the sent events left the queue")
    }

    func testOversizeGzipBodyIsSplitBeforeSending() {
        var settings = UploadSettings.defaults
        settings.maxCompressedBytes = 420
        settings.flushThreshold = 10_000
        use(settings)
        h.start()
        h.track(8)
        h.background()
        XCTAssertLessThan(h.transport.requests[0].eventIds.count, 8)
        XCTAssertLessThanOrEqual(h.transport.requests[0].httpBody!.count, 420)
        while h.transport.pendingCount > 0 { h.respond(202) }
        XCTAssertTrue(h.queuedIds.isEmpty)
    }

    func testDecompressedByteCapLimitsTheBatch() {
        var settings = UploadSettings.defaults
        settings.maxDecompressedBytes = 2_000
        settings.flushThreshold = 10_000
        use(settings)
        h.start()
        h.track(10)
        h.background()
        let first = h.transport.requests[0]
        XCTAssertLessThan(first.eventIds.count, 10)
        XCTAssertLessThanOrEqual(first.ndjsonLines.map { $0.utf8.count + 1 }.reduce(0, +), 2_000)
    }

    // MARK: Retry identity

    func testBatchIdIsReusedOnRetryAndSentAtIsRefreshed() {
        h.start()
        h.track(3)
        h.background()
        h.respond(503)
        let retryAt = h.clock.now.addingTimeInterval(22.5) // random 0.5 → 15 + 7.5 s
        h.advance(3_600)
        XCTAssertEqual(h.transport.requests.count, 2)
        let (first, second) = (h.transport.requests[0], h.transport.requests[1])
        XCTAssertEqual(first.batchId, second.batchId)
        XCTAssertEqual(first.eventIds, second.eventIds)
        XCTAssertEqual(first.httpBody, second.httpBody)
        XCTAssertNotEqual(first.sentAt, second.sentAt)
        XCTAssertEqual(second.sentAt, Timestamp.string(from: retryAt))
    }

    // MARK: Response handling (what each status does to the batch)

    func test202DeletesAcceptedAndRejectedEvents() {
        h.start()
        h.track(3)
        let ids = h.queuedIds
        h.background()
        h.respond(202, body: #"{"accepted":2,"rejected":[{"event_id":"\#(ids[1])","reason":"invalid_envelope"}]}"#)
        XCTAssertTrue(h.queuedIds.isEmpty)
        XCTAssertEqual(h.transport.requests.count, 1, "rejected events are never resent")
    }

    func test202WithoutRejectedOrWithUnreadableBodyStillDeletes() {
        h.start()
        h.track(2)
        h.background()
        h.respond(202, body: "not json")
        XCTAssertTrue(h.queuedIds.isEmpty)
    }

    func test400DeletesTheBatch() {
        h.start()
        h.track(2)
        h.background()
        h.respond(400, body: #"{"error":"invalid_body"}"#)
        XCTAssertTrue(h.queuedIds.isEmpty)
        XCTAssertNil(h.onQueue { h.uploader.scheduledNextAttempt })
    }

    func test401IsTheKillSwitch() {
        h.start()
        h.track(3)
        h.background()
        h.respond(401, body: #"{"error":"invalid_key"}"#)
        XCTAssertEqual(h.unauthorizedCalls, 1)
        XCTAssertTrue(h.onQueue { h.uploader.isStopped })
        XCTAssertTrue(h.pipeline.isDisabled)
        XCTAssertTrue(h.queuedIds.isEmpty, "queue dropped")

        // Nothing is captured or sent any more in this run.
        h.track(150)
        XCTAssertTrue(h.queuedIds.isEmpty, "capture stopped")
        h.background()
        h.uploader.appDidBecomeActive()
        h.advance(7_200)
        XCTAssertEqual(h.transport.requests.count, 1)
        XCTAssertNil(h.onQueue { h.uploader.scheduledNextAttempt })
    }

    func test403IsNotSpecialAndIsRetriedLikeAnyOtherStatus() {
        h.start()
        h.track(3)
        let ids = h.queuedIds
        h.background()
        h.respond(403)
        XCTAssertEqual(h.unauthorizedCalls, 0)
        XCTAssertFalse(h.onQueue { h.uploader.isStopped })
        XCTAssertEqual(h.queuedIds, ids, "queue kept")
        XCTAssertNotNil(h.onQueue { h.uploader.scheduledNextAttempt })
        h.advance(3_600)
        XCTAssertEqual(h.transport.requests.count, 2)
        XCTAssertEqual(h.transport.requests[1].batchId, h.transport.requests[0].batchId)
    }

    func test413SplitsInHalvesWithNewBatchIds() {
        h.start()
        h.track(4)
        let ids = h.queuedIds
        h.background()
        h.respond(413)
        XCTAssertEqual(h.transport.requests[1].eventIds, Array(ids.prefix(2)))
        XCTAssertNotEqual(h.transport.requests[1].batchId, h.transport.requests[0].batchId)
        h.respond(202)
        XCTAssertEqual(h.transport.requests[2].eventIds, Array(ids.suffix(2)))
        XCTAssertNotEqual(h.transport.requests[2].batchId, h.transport.requests[1].batchId)
        h.respond(202)
        XCTAssertTrue(h.queuedIds.isEmpty)
    }

    func test413OnASingle40KBEventDropsIt() {
        // A single event the API rejects as too large (413) is dropped instead of blocking the queue.
        h.start()
        h.pipeline.track(.screenView, properties: ["blob": .string(String(repeating: "x", count: 40_000))])
        h.track(1)
        let ids = h.queuedIds
        h.background()
        h.respond(413)                       // [big, small] → split
        XCTAssertEqual(h.transport.requests[1].eventIds, [ids[0]])
        h.respond(413)                       // big alone → deleted
        XCTAssertEqual(h.queuedIds, [ids[1]])
        XCTAssertEqual(h.transport.requests[2].eventIds, [ids[1]])
        h.respond(202)
        XCTAssertTrue(h.queuedIds.isEmpty)
    }

    func test429HonoursRetryAfter() {
        // The retry waits for Retry-After: 120 s ± 1 s.
        h.start()
        h.track(2)
        h.background()
        let sentAt = h.clock.now
        h.respond(429, headers: ["retry-after": "120"])
        XCTAssertEqual(h.onQueue { h.uploader.scheduledNextAttempt }, sentAt.addingTimeInterval(120))
        h.advance(119)
        XCTAssertEqual(h.transport.requests.count, 1)
        h.background() // a trigger inside the wait doesn't jump it
        XCTAssertEqual(h.transport.requests.count, 1)
        h.advance(1)
        XCTAssertEqual(h.transport.requests.count, 2)
        XCTAssertEqual(h.transport.requests[1].batchId, h.transport.requests[0].batchId)
        h.respond(202)
        XCTAssertTrue(h.queuedIds.isEmpty)
    }

    func test429WithoutRetryAfterBacksOff() {
        h.random = 0
        h.start()
        h.track(1)
        h.background()
        h.respond(429)
        XCTAssertEqual(h.onQueue { h.uploader.scheduledNextAttempt }, h.clock.now.addingTimeInterval(15))
    }

    func test5xxTimeoutAndNetworkErrorsKeepTheBatchAndBackOff() {
        h.random = 1
        h.start()
        h.track(2)
        let ids = h.queuedIds
        h.background()
        h.respond(500)
        XCTAssertEqual(h.onQueue { h.uploader.scheduledNextAttempt }, h.clock.now.addingTimeInterval(30))
        h.advance(30)
        h.fail(URLError(.timedOut))
        XCTAssertEqual(h.onQueue { h.uploader.scheduledNextAttempt }, h.clock.now.addingTimeInterval(60))
        h.advance(60)
        h.fail(URLError(.notConnectedToInternet))
        XCTAssertEqual(h.onQueue { h.uploader.scheduledNextAttempt }, h.clock.now.addingTimeInterval(120))
        XCTAssertEqual(h.queuedIds, ids)
        XCTAssertEqual(h.transport.requests.count, 3)
    }

    func testUnexpectedStatusIsTreatedAsTransient() {
        h.start()
        h.track(1)
        h.background()
        h.respond(404)
        XCTAssertEqual(h.queuedIds.count, 1)
        XCTAssertNotNil(h.onQueue { h.uploader.scheduledNextAttempt })
    }

    func testBackoffDelaysGrowAndCapAtOneHour() {
        let s = UploadSettings.defaults
        XCTAssertEqual(EventUploader.backoffDelay(failures: 1, settings: s, random: 1), 30)
        XCTAssertEqual(EventUploader.backoffDelay(failures: 1, settings: s, random: 0), 15)
        XCTAssertEqual(EventUploader.backoffDelay(failures: 2, settings: s, random: 1), 60)
        XCTAssertEqual(EventUploader.backoffDelay(failures: 7, settings: s, random: 1), 1_920)
        XCTAssertEqual(EventUploader.backoffDelay(failures: 8, settings: s, random: 1), 3_600)
        XCTAssertEqual(EventUploader.backoffDelay(failures: 50, settings: s, random: 1), 3_600)
        XCTAssertEqual(EventUploader.backoffDelay(failures: 50, settings: s, random: 0), 1_800)
        XCTAssertEqual(EventUploader.backoffDelay(failures: 10_000, settings: s, random: 0.5), 2_700)
    }

    func testAlways500StaysWithinTwelveAttemptsInTheFirstHour() {
        // At most 12 attempts in the first hour of a lasting outage: worst case (shortest jitter) and a few random draws.
        for random in [0.0, 0.25, 0.5, 0.999] {
            use(.defaults)
            h.random = random
            h.start()
            h.track(5)
            h.background()
            let start = h.clock.now
            var attemptsInFirstHour = 0
            while h.clock.now.timeIntervalSince(start) < 3_600 {
                while h.transport.pendingCount > 0 {
                    attemptsInFirstHour += 1
                    h.respond(500)
                }
                guard let due = h.clock.nextDue else { break }
                h.advance(max(0, due.timeIntervalSince(h.clock.now)))
            }
            XCTAssertLessThanOrEqual(attemptsInFirstHour, 12, "random \(random)")
            XCTAssertGreaterThanOrEqual(attemptsInFirstHour, 6, "random \(random)")

            // Many hours later the delay sits at the cap, never more.
            for _ in 0..<20 {
                while h.transport.pendingCount > 0 { h.respond(500) }
                guard let due = h.clock.nextDue else { break }
                h.advance(max(0, due.timeIntervalSince(h.clock.now)))
            }
            while h.transport.pendingCount > 0 { h.respond(500) }
            guard let next = h.onQueue({ h.uploader.scheduledNextAttempt }) else {
                return XCTFail("no retry scheduled")
            }
            let wait = next.timeIntervalSince(h.clock.now)
            XCTAssertLessThanOrEqual(wait, 3_600)
            XCTAssertGreaterThanOrEqual(wait, 1_800)
        }
    }

    func testBackoffResetsAfterA202() {
        h.random = 1
        h.start()
        h.track(1)
        h.background()
        h.respond(500)
        h.advance(30)
        h.respond(500)
        h.advance(60)
        h.respond(202)
        h.track(1)
        h.background()
        h.respond(500)
        XCTAssertEqual(h.onQueue { h.uploader.scheduledNextAttempt }, h.clock.now.addingTimeInterval(30))
    }

    // MARK: Network, opt-out

    func testNoNetworkMeansNoAttemptThenSendsWhenItReturns() {
        use(.defaults, network: .offline)
        h.start()
        h.track(150)
        h.background()
        h.advance(3_600)
        XCTAssertTrue(h.transport.requests.isEmpty)
        h.network.set(.other)
        h.settle()
        XCTAssertEqual(h.transport.requests.count, 1)
        h.respond(202)
        XCTAssertTrue(h.queuedIds.isEmpty)
    }

    func testOptOutSendsNothing() {
        h.start()
        h.track(3)
        h.pipeline.setOptedOut(true)
        h.settle()
        h.track(200)
        h.background()
        h.uploader.appDidBecomeActive()
        h.advance(3_600)
        XCTAssertTrue(h.transport.requests.isEmpty)
    }

    func testOptOutDuringARequestCancelsIt() {
        h.start()
        h.track(3)
        h.background()
        h.pipeline.setOptedOut(true)
        h.settle()
        XCTAssertTrue(h.transport.sent[0].cancellable.cancelled)
        h.respond(500)
        h.advance(3_600)
        XCTAssertEqual(h.transport.requests.count, 1)
        XCTAssertNil(h.onQueue { h.uploader.scheduledNextAttempt })
    }

    // MARK: Flush triggers

    func testColdStartFlushesANonEmptyQueue() {
        h.track(3)               // events from an earlier run, nothing started yet
        XCTAssertTrue(h.transport.requests.isEmpty)
        h.start()
        XCTAssertEqual(h.transport.requests.count, 1)
        XCTAssertEqual(h.transport.requests[0].eventIds.count, 3)
    }

    func testColdStartWithAnEmptyQueueSendsNothing() {
        h.start()
        XCTAssertTrue(h.transport.requests.isEmpty)
    }

    func testBackgroundFlushesAndHoldsBackgroundTimeUntilAnswered() {
        h.start()
        h.track(2)
        XCTAssertTrue(h.transport.requests.isEmpty)
        h.background()
        XCTAssertEqual(h.transport.requests.count, 1)
        XCTAssertEqual(h.backgroundTasks.begun, 1)
        XCTAssertEqual(h.backgroundTasks.ended, 0)
        h.respond(202)
        XCTAssertEqual(h.backgroundTasks.ended, 1)
    }

    func testBackgroundExpiryCancelsAndTheSameBatchGoesAtTheNextTrigger() {
        h.start()
        h.track(2)
        h.background()
        h.backgroundTasks.expireAll()
        h.settle()
        XCTAssertTrue(h.transport.sent[0].cancellable.cancelled)
        XCTAssertEqual(h.backgroundTasks.ended, 1)
        h.fail(URLError(.cancelled)) // late answer of the cancelled task is ignored
        XCTAssertEqual(h.queuedIds.count, 2)
        XCTAssertNil(h.onQueue { h.uploader.scheduledNextAttempt }, "a cut-short flush is not a failure")
        h.background()
        XCTAssertEqual(h.transport.requests.count, 2)
        XCTAssertEqual(h.transport.requests[1].batchId, h.transport.requests[0].batchId)
    }

    func testThresholdOf100Flushes() {
        h.start()
        h.track(99)
        XCTAssertTrue(h.transport.requests.isEmpty)
        h.track(1)
        XCTAssertEqual(h.transport.requests.count, 1)
        XCTAssertEqual(h.transport.requests[0].eventIds.count, 100)
    }

    func testForegroundTimerFlushesEveryFiveMinutesWhenNotEmpty() {
        h.start()
        h.uploader.appDidBecomeActive()
        h.settle()
        h.advance(300)
        XCTAssertTrue(h.transport.requests.isEmpty, "empty queue: nothing to send")
        h.track(5)
        h.advance(299)
        XCTAssertTrue(h.transport.requests.isEmpty)
        h.advance(1)
        XCTAssertEqual(h.transport.requests.count, 1)
        h.respond(202)
        h.track(1)
        h.advance(300)
        XCTAssertEqual(h.transport.requests.count, 2)
    }

    func testForegroundTimerStopsInTheBackground() {
        h.start()
        h.uploader.appDidBecomeActive()
        h.settle()
        h.background()        // empty queue: no request
        h.track(5)
        h.advance(3_000)
        XCTAssertTrue(h.transport.requests.isEmpty)
    }

    func testCellularSkipsTheTimerFlushBelow100Events() {
        var settings = UploadSettings.defaults
        settings.flushThreshold = 10_000 // isolate the timer
        use(settings, network: .cellular)
        h.start()
        h.uploader.appDidBecomeActive()
        h.track(99)
        h.advance(300)
        XCTAssertTrue(h.transport.requests.isEmpty)
        h.track(1)
        h.advance(300)
        XCTAssertEqual(h.transport.requests.count, 1, "≥ 100 events: the timer flush runs on cellular")
    }

    func testCellularStillFlushesOnBackgroundAndColdStart() {
        use(.defaults, network: .cellular)
        h.track(3)
        h.start()
        XCTAssertEqual(h.transport.requests.count, 1, "cold start")
        h.respond(202)
        h.track(3)
        h.background()
        XCTAssertEqual(h.transport.requests.count, 2, "background")
    }

    // MARK: Crash safety

    func testKillMidRequestLeavesEventsQueuedAndTheyAreResent() {
        h.start()
        h.track(4)
        let ids = h.queuedIds
        h.background()
        // Process killed: no answer ever arrives. The disk queue still has everything.
        XCTAssertEqual(h.queuedIds, ids)
        h.relaunch()
        XCTAssertEqual(h.transport.requests.count, 2)
        XCTAssertEqual(h.transport.requests.last?.eventIds, ids)
    }
}
