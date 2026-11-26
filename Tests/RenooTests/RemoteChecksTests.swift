import XCTest
@testable import Renoo

/// `GET /health-check` and `GET /offers` with a fake transport and clock.
final class RemoteChecksTests: XCTestCase {
    private var harness: TestHarness!
    private var environment: SDKEnvironment!
    private var transport: FakeTransport!
    private var clock: FakeClock!
    private var offers: PendingOfferStore!
    private var checks: RemoteChecks!
    private var unauthorizedCalls = 0
    /// `.everyone` keeps the tracking gate open; the gate tests switch to `.subscribersOnly`.
    private var scope: Configuration.TrackingScope = .everyone

    private let healthURL = URL(string: "https://api.example.com/health-check")!
    private let offersURL = URL(string: "https://api.example.com/offers")!
    private let offerBody = #"{"offer_id":"winback_30","discount":{"percent":30},"template":null}"#

    override func setUp() {
        super.setUp()
        harness = TestHarness()
        environment = harness.makeEnvironment(scope: scope)
        transport = FakeTransport()
        clock = FakeClock()
        offers = PendingOfferStore()
        unauthorizedCalls = 0
        checks = makeChecks()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    private var pipeline: EventPipeline { environment.pipeline }

    /// A fresh fixture inside a looping test.
    private func fresh() {
        harness.tearDown()
        setUp()
    }

    private func makeChecks() -> RemoteChecks {
        let checks = RemoteChecks(
            healthCheckURL: healthURL,
            offersURL: offersURL,
            apiKey: "pk_test_secret",
            pipeline: pipeline,
            offers: offers,
            queue: environment.queue,
            logger: harness.logger,
            dependencies: .init(transport: transport, clock: clock)
        )
        let pipeline = pipeline
        pipeline.trackingGateListener = checks
        checks.onUnauthorized = { [unowned self] in
            unauthorizedCalls += 1
            pipeline.disable()
        }
        return checks
    }

    private func settle() {
        for _ in 0..<4 { environment.queue.sync {} }
    }

    private func start() {
        checks.start()
        settle()
    }

    private func respond(_ status: Int, body: String = "") {
        transport.respond(status, body: body)
        settle()
    }

    private func fail() {
        transport.fail(URLError(.notConnectedToInternet))
        settle()
    }

    private func foreground() {
        checks.appDidBecomeActive()
        settle()
    }

    private var paths: [String] { transport.requests.compactMap { $0.url?.path } }

    /// Start-up with a healthy key, leaving the offers request unanswered.
    private func startHealthy() {
        start()
        respond(200)
    }

    // MARK: Health check

    func testStartUpCallsHealthCheckOffTheMainThreadWithTheKey() throws {
        XCTAssertTrue(Thread.isMainThread)
        start()
        let sent = try XCTUnwrap(transport.sent.first)
        XCTAssertFalse(sent.onMainThread)
        XCTAssertEqual(sent.request.url, healthURL)
        XCTAssertEqual(sent.request.httpMethod, "GET")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer pk_test_secret")
        XCTAssertNil(sent.request.httpBody)
        XCTAssertNil(sent.request.value(forHTTPHeaderField: RemoteChecks.anonymousIdHeader), "health check carries no identity")
        XCTAssertEqual(transport.requests.count, 1, "offers wait for the health check")
    }

    func testHealth200ThenFetchesOffers() {
        startHealthy()
        XCTAssertEqual(paths, ["/health-check", "/offers"])
        XCTAssertEqual(unauthorizedCalls, 0)
    }

    func testHealth5xxAndNetworkErrorCarryOn() {
        for outcome in [500, 503, 0] {
            fresh()
            start()
            if outcome == 0 { fail() } else { respond(outcome) }
            XCTAssertEqual(paths, ["/health-check", "/offers"], "outcome \(outcome)")
            XCTAssertFalse(pipeline.isDisabled)
        }
    }

    func testHealth401IsTheKillSwitch() {
        pipeline.track(.screenView)
        settle()
        XCTAssertEqual(pipeline.queuedEvents().count, 1)
        start()
        respond(401)
        settle()
        XCTAssertEqual(unauthorizedCalls, 1)
        XCTAssertEqual(paths, ["/health-check"], "GET /offers skipped")
        XCTAssertTrue(pipeline.isDisabled)
        XCTAssertTrue(pipeline.queuedEvents().isEmpty, "queue dropped")

        pipeline.track(.screenView)
        foreground()
        clock.advance(by: RemoteChecks.offersInterval * 2)
        foreground()
        XCTAssertTrue(pipeline.queuedEvents().isEmpty, "capture stopped")
        XCTAssertEqual(transport.requests.count, 1, "nothing sent until the next start-up")
    }

    func testNextStartUpChecksAgain() {
        start()
        respond(401)
        checks = makeChecks()  // a new launch builds new checks
        start()
        XCTAssertEqual(paths, ["/health-check", "/health-check"])
    }

    // MARK: Offers request

    func testOffersSendsIdentityInHeadersOnly() throws {
        startHealthy()
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.url, offersURL)
        XCTAssertNil(request.url?.query, "no identity in the URL")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pk_test_secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Renoo-Anonymous-Id"), pipeline.anonymousId)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Renoo-User-Id"), "no user ID before login")
        XCTAssertFalse(try XCTUnwrap(transport.sent.last).onMainThread)
    }

    func testOffersSendsTheUserIdOnceIdentified() throws {
        pipeline.identify(userId: "user-42")
        settle()
        startHealthy()
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Renoo-User-Id"), "user-42")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Renoo-Anonymous-Id"), pipeline.anonymousId)
    }

    func testOffers200KeepsThePendingOffer() {
        startHealthy()
        respond(200, body: offerBody)
        let offer = offers.current
        XCTAssertEqual(offer?.json["offer_id"], "winback_30")
        XCTAssertEqual(offer?.json["discount"], ["percent": 30])
        XCTAssertEqual(offer?.json["template"], .null)
    }

    func testOffers200WithoutAJSONObjectIsIgnoredAndRetried() {
        startHealthy()
        respond(200, body: "[1,2]")
        XCTAssertNil(offers.current)
        foreground()
        XCTAssertEqual(paths.filter { $0 == "/offers" }.count, 2, "the window was not used up")
    }

    func testOffers204ClearsThePendingOffer() {
        startHealthy()
        respond(200, body: offerBody)
        XCTAssertNotNil(offers.current)
        clock.advance(by: RemoteChecks.offersInterval)
        foreground()
        respond(204)
        XCTAssertNil(offers.current)
        XCTAssertEqual(unauthorizedCalls, 0)
    }

    func testOffers401IsTheKillSwitch() {
        startHealthy()
        respond(200, body: offerBody)
        clock.advance(by: RemoteChecks.offersInterval)
        foreground()
        respond(401)
        XCTAssertEqual(unauthorizedCalls, 1)
        XCTAssertNil(offers.current, "offer forgotten")
        XCTAssertTrue(pipeline.isDisabled)
        clock.advance(by: RemoteChecks.offersInterval)
        foreground()
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testOffers503AndOtherErrorsDoNothingAndRetryOnTheNextTrigger() {
        for outcome in [503, 500, 404, 0] {
            fresh()
            startHealthy()
            respond(200, body: offerBody)
            clock.advance(by: RemoteChecks.offersInterval)
            foreground()
            if outcome == 0 { fail() } else { respond(outcome) }
            XCTAssertEqual(offers.current?.json["offer_id"], "winback_30", "kept as is (\(outcome))")
            XCTAssertEqual(unauthorizedCalls, 0)
            XCTAssertFalse(pipeline.isDisabled)
            foreground()
            XCTAssertEqual(paths.filter { $0 == "/offers" }.count, 3, "retried at once (\(outcome))")
        }
    }

    // MARK: Foreground throttle

    func testForegroundFetchesAtMostEverySixHours() {
        startHealthy()
        respond(204)
        foreground()
        clock.advance(by: RemoteChecks.offersInterval - 1)
        foreground()
        XCTAssertEqual(paths.filter { $0 == "/offers" }.count, 1)
        clock.advance(by: 1)
        foreground()
        XCTAssertEqual(paths.filter { $0 == "/offers" }.count, 2)
    }

    func testForegroundDuringStartUpDoesNotDuplicate() {
        start()
        foreground()  // health check still in flight
        XCTAssertEqual(paths, ["/health-check"])
        respond(200)
        foreground()  // start-up offers still in flight
        XCTAssertEqual(paths, ["/health-check", "/offers"])
    }

    func testForegroundAfterAFailedStartUpFetchRetries() {
        startHealthy()
        respond(503)
        foreground()
        XCTAssertEqual(paths, ["/health-check", "/offers", "/offers"])
    }

    // MARK: Identity and opt-out

    func testResetClearsTheOfferIgnoresALateAnswerAndRefetches() {
        startHealthy()
        respond(200, body: offerBody)
        clock.advance(by: RemoteChecks.offersInterval)
        foreground()
        let pending = transport.pendingCount
        XCTAssertEqual(pending, 1)
        checks.identityReset()
        settle()
        XCTAssertNil(offers.current)
        respond(200, body: offerBody)  // answer for the previous user
        XCTAssertNil(offers.current)
        foreground()  // no 6-hour wait after a logout
        XCTAssertEqual(paths.filter { $0 == "/offers" }.count, 3)
    }

    func testNoOffersFetchWhileOptedOut() {
        pipeline.setOptedOut(true)
        settle()
        startHealthy()
        XCTAssertEqual(paths, ["/health-check"])
        foreground()
        XCTAssertEqual(paths, ["/health-check"])
    }

    // MARK: Tracking gate

    /// Rebuilds the fixture with `trackingScope: .subscribersOnly`: the gate starts closed (unknown).
    private func useSubscribersOnly() {
        scope = .subscribersOnly
        fresh()
    }

    private func openGate() {
        pipeline.setTrackingState(.tracked, scope: .subscribersOnly)
        settle()
    }

    private func closeGate() {
        pipeline.setTrackingState(.notTracked, scope: .subscribersOnly)
        settle()
    }

    private var offersCount: Int { paths.filter { $0 == "/offers" }.count }

    func testUntrackedAtStartUpSendsNoOffersRequest() throws {
        for closed in [TrackingState.unknown, .notTracked] {
            useSubscribersOnly()
            if closed == .notTracked { closeGate() }
            startHealthy()
            XCTAssertEqual(paths, ["/health-check"], "\(closed)")
            let health = try XCTUnwrap(transport.requests.first)
            XCTAssertNil(health.value(forHTTPHeaderField: RemoteChecks.anonymousIdHeader), "health check carries no identity")
            XCTAssertNil(health.value(forHTTPHeaderField: RemoteChecks.userIdHeader))
        }
    }

    func testForegroundWhileUntrackedSendsNothing() {
        useSubscribersOnly()
        pipeline.identify(userId: "user-42")
        closeGate()
        startHealthy()
        foreground()
        clock.advance(by: RemoteChecks.offersInterval * 2)
        foreground()
        XCTAssertEqual(paths, ["/health-check"])
        XCTAssertTrue(transport.requests.allSatisfy {
            $0.value(forHTTPHeaderField: RemoteChecks.anonymousIdHeader) == nil
                && $0.value(forHTTPHeaderField: RemoteChecks.userIdHeader) == nil
        }, "no identity leaves the device for an untracked user")
    }

    func testGateOpeningLaterFetchesAndSkippedFetchesDoNotUseUpTheWindow() throws {
        useSubscribersOnly()
        startHealthy()
        foreground()
        XCTAssertEqual(paths, ["/health-check"])
        openGate()
        XCTAssertEqual(paths, ["/health-check", "/offers"])
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: RemoteChecks.anonymousIdHeader), pipeline.anonymousId)
        respond(200, body: offerBody)
        XCTAssertEqual(offers.current?.json["offer_id"], "winback_30")
        foreground()
        XCTAssertEqual(offersCount, 1, "the answered fetch starts the window")
    }

    func testGateOpeningDuringTheHealthCheckWaitsForIt() {
        useSubscribersOnly()
        start()
        openGate()
        XCTAssertEqual(paths, ["/health-check"], "start-up owns the first fetch")
        respond(200)
        XCTAssertEqual(paths, ["/health-check", "/offers"])
    }

    func testGateOpeningInsideTheWindowAfterAnEarlierFetchDoesNotFetch() {
        useSubscribersOnly()
        openGate()
        startHealthy()
        respond(200, body: offerBody)
        XCTAssertEqual(offersCount, 1)
        closeGate()
        clock.advance(by: RemoteChecks.offersInterval - 1)
        openGate()
        XCTAssertEqual(offersCount, 1, "still inside the 6-hour window")
        clock.advance(by: 1)
        foreground()
        XCTAssertEqual(offersCount, 2)
    }

    func testGateClosingClearsTheOfferAndDropsAnAnswerInFlight() throws {
        useSubscribersOnly()
        openGate()
        startHealthy()
        respond(200, body: offerBody)
        XCTAssertNotNil(offers.current)
        closeGate()
        XCTAssertNil(offers.current, "offers are only for tracked users")

        clock.advance(by: RemoteChecks.offersInterval)
        openGate()
        XCTAssertEqual(offersCount, 2)
        let inFlight = try XCTUnwrap(transport.sent.last)
        closeGate()
        XCTAssertTrue(inFlight.cancellable.cancelled)
        XCTAssertFalse(checks.hasOffersRequestInFlight)
        respond(200, body: offerBody)  // late answer after the gate closed
        XCTAssertNil(offers.current)
        foreground()
        XCTAssertEqual(offersCount, 2, "nothing sent while closed")
    }

    func testGateChangesAfterTheKillSwitchSendNothing() {
        useSubscribersOnly()
        start()
        respond(401)
        openGate()
        foreground()
        XCTAssertEqual(paths, ["/health-check"])
    }

    // MARK: Store and observers

    func testObserverGetsTheCurrentValueThenChangesOnTheMainActor() {
        let first = expectation(description: "current value")
        let second = expectation(description: "offer")
        let third = expectation(description: "cleared")
        final class Box: @unchecked Sendable { var values: [PendingOffer?] = [] }
        let box = Box()
        let expectations = [first, second, third]
        let token = offers.addObserver { offer in
            XCTAssertTrue(Thread.isMainThread)
            box.values.append(offer)
            if box.values.count <= expectations.count { expectations[box.values.count - 1].fulfill() }
        }
        wait(for: [first], timeout: 2)
        offers.set(PendingOffer(json: ["offer_id": "a"]))
        offers.set(PendingOffer(json: ["offer_id": "a"]))  // unchanged: no call
        wait(for: [second], timeout: 2)
        offers.set(nil)
        wait(for: [third], timeout: 2)
        XCTAssertEqual(box.values, [nil, PendingOffer(json: ["offer_id": "a"]), nil])

        offers.removeObserver(token)
        offers.set(PendingOffer(json: ["offer_id": "b"]))
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(box.values.count, 3, "removed observers hear nothing")
    }
}

/// The checks inside a real `SDKCore` and the public API.
final class RemoteChecksWiringTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let uploads = FakeTransport()
    private let remote = FakeTransport()
    private let clock = FakeClock()
    private var remoteFactoryCalls = 0

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        remoteFactoryCalls = 0
    }

    override func tearDown() {
        Renoo._setCoreForTesting(nil)
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeCore(url: String?, scope: Configuration.TrackingScope = .everyone) -> SDKCore {
        var configuration = Configuration(apiKey: "pk_test", purchaseHandler: { _ in .cancelled })
        configuration.trackingScope = scope
        configuration.logLevel = .none
        configuration.automaticScreenTracking = false
        configuration.ingestURL = url.flatMap(URL.init(string:))
        return SDKCore(
            configuration: configuration,
            defaults: defaults,
            storeDirectory: directory,
            uploadDependencies: { [self] _ in
                EventUploader.Dependencies(
                    transport: uploads, clock: clock, network: FakeNetwork(),
                    backgroundTasks: FakeBackgroundTasks(), random: { 0.5 }
                )
            },
            remoteDependencies: { [self] _ in
                remoteFactoryCalls += 1
                return RemoteChecks.Dependencies(transport: remote, clock: clock)
            }
        )
    }

    private func settle(_ core: SDKCore) {
        for _ in 0..<4 { core.environment.queue.sync {} }
    }

    func testCaptureOnlySkipsBothCalls() {
        let core = makeCore(url: nil)
        XCTAssertNil(core.remoteChecks)
        core.start()
        core.lifecycle.becameActive()
        settle(core)
        XCTAssertEqual(remoteFactoryCalls, 0)
        XCTAssertTrue(remote.requests.isEmpty)
        Renoo._setCoreForTesting(core)
        XCTAssertNil(Renoo.pendingOffer)
    }

    func testStartUpAndForegroundUseTheBaseURL() {
        let core = makeCore(url: "https://api.example.com/")
        core.start()
        settle(core)
        XCTAssertEqual(remote.requests.map { $0.url?.absoluteString }, ["https://api.example.com/health-check"])
        remote.respond(200)
        settle(core)
        remote.respond(204)
        settle(core)
        clock.advance(by: RemoteChecks.offersInterval)
        core.lifecycle.becameActive()
        settle(core)
        XCTAssertEqual(remote.requests.last?.url?.absoluteString, "https://api.example.com/offers")
        XCTAssertEqual(remote.requests.count, 3)
    }

    func testPublicPendingOfferAndResetAndOptOut() {
        let core = makeCore(url: "https://api.example.com")
        Renoo._setCoreForTesting(core)
        XCTAssertNil(Renoo.pendingOffer)
        core.start()
        settle(core)
        remote.respond(200)
        settle(core)
        remote.respond(200, body: #"{"offer_id":"x"}"#)
        settle(core)
        XCTAssertEqual(Renoo.pendingOffer, PendingOffer(json: ["offer_id": "x"]))

        Renoo.reset()
        settle(core)
        XCTAssertNil(Renoo.pendingOffer, "logout forgets the previous user's offer")

        core.lifecycle.becameActive()
        settle(core)
        remote.respond(200, body: #"{"offer_id":"y"}"#)
        settle(core)
        XCTAssertEqual(Renoo.pendingOffer?.json["offer_id"], "y")
        Renoo.optOut()
        settle(core)
        XCTAssertNil(Renoo.pendingOffer)
    }

    func testUpload401FiresTheKillSwitchEverywhere() {
        let core = makeCore(url: "https://api.example.com")
        core.start()
        settle(core)
        remote.respond(200)
        settle(core)
        remote.respond(200, body: #"{"offer_id":"x"}"#)
        settle(core)
        core.lifecycle.becameActive()
        core.screens.trackScreen(name: "Home", source: .manual)
        core.lifecycle.enteredBackground()
        settle(core)
        XCTAssertEqual(uploads.requests.first?.url?.path, "/events/sdk")
        uploads.respond(401)
        settle(core)

        XCTAssertTrue(core.environment.pipeline.isDisabled)
        XCTAssertTrue(core.environment.pipeline.queuedEvents().isEmpty, "queue dropped")
        XCTAssertNil(core.pendingOffers.current)
        core.screens.trackScreen(name: "Settings", source: .manual)
        clock.advance(by: RemoteChecks.offersInterval)
        core.lifecycle.becameActive()
        core.lifecycle.enteredBackground()
        settle(core)
        XCTAssertTrue(core.environment.pipeline.queuedEvents().isEmpty, "capture stopped")
        XCTAssertEqual(uploads.requests.count, 1)
        XCTAssertEqual(remote.requests.count, 2, "no more GET /offers")
    }

    func testOffersFollowTheTrackingGateInsideTheCore() {
        let core = makeCore(url: "https://api.example.com", scope: .subscribersOnly)
        let pipeline = core.environment.pipeline
        // Only the health check: no subscription state yet, so the gate is closed.
        core.remoteChecks?.start()
        settle(core)
        remote.respond(200)
        settle(core)
        core.lifecycle.becameActive()
        settle(core)
        XCTAssertEqual(remote.requests.map { $0.url?.path }, ["/health-check"])

        pipeline.setTrackingState(.tracked, scope: .subscribersOnly)
        settle(core)
        XCTAssertEqual(remote.requests.map { $0.url?.path }, ["/health-check", "/offers"])
        remote.respond(200, body: #"{"offer_id":"x"}"#)
        settle(core)
        XCTAssertNotNil(core.pendingOffers.current)

        pipeline.setTrackingState(.notTracked, scope: .subscribersOnly)
        settle(core)
        XCTAssertNil(core.pendingOffers.current)
    }

    func testPublicObserverBeforeConfigureReturnsNil() {
        Renoo._setCoreForTesting(nil)
        XCTAssertNil(Renoo.addPendingOfferObserver { _ in })
    }
}
