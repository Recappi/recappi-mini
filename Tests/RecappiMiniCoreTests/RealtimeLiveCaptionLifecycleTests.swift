import XCTest
@testable import RecappiMini

/// Phase 1 — lifecycle state machine for `RealtimeLiveCaptionActor`.
/// Each test pins a specific transition through the lifecycle enum.
/// I/O is faked through `MockRealtimeSessionConnector` so the lifecycle
/// runs without touching the network.
final class RealtimeLiveCaptionLifecycleTests: XCTestCase {
    // MARK: - Happy path

    /// `.created → .claiming → .live` when the claim resolves and the
    /// socket opens successfully.
    func testStartAdvancesFromCreatedToLive() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        let beforeStart = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(beforeStart, .created)

        await actor.start()
        // Allow the claim Task to dispatch and resolve.
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        // Yield twice so the actor reentrancy can process the post-
        // claim, post-socket-open transitions.
        await Task.yield()
        await Task.yield()

        let afterStart = await actor.lifecycleSnapshotForTesting()
        switch afterStart {
        case .live(let generation):
            XCTAssertGreaterThan(generation, 0)
        default:
            XCTFail("Expected .live, got \(afterStart)")
        }
    }

    // MARK: - Stop during claim

    /// `.claiming → .stopping → .stopped` when `stop()` arrives while
    /// the claim is still in flight. The stale claim task must be
    /// cancelled and the socket must NOT be installed when the (now-
    /// late) claim eventually resolves.
    func testStopDuringClaimDropsStaleClaim() async {
        let connector = MockRealtimeSessionConnector()
        connector.holdClaim = true // Suspend the claim until released.
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        await actor.start()
        await Task.yield()

        let snapshotMidClaim = await actor.lifecycleSnapshotForTesting()
        switch snapshotMidClaim {
        case .claiming:
            break
        default:
            XCTFail("Expected .claiming before stop, got \(snapshotMidClaim)")
        }

        let entries = await actor.stop(saveTo: nil)
        XCTAssertEqual(entries, [], "Stop during claim returns no entries.")

        let afterStop = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(afterStop, .stopped)

        // Release the held claim so it eventually resolves. The
        // post-claim guards inside the actor must NOT install a
        // socket because the lifecycle has already advanced to
        // `.stopped`.
        connector.releaseClaim()
        // Give the claim Task time to run its now-stale completion.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let stillStopped = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(stillStopped, .stopped, "Stale claim must not resurrect the lifecycle.")
        XCTAssertEqual(
            connector.openSocketCallCount, 0,
            "Stop must prevent openSocket from being called when stop wins the race."
        )
    }

    // MARK: - Stop during live

    /// `.live → .stopping → .stopped` on a clean stop. The accumulated
    /// entries must be returned.
    func testStopDuringLiveReturnsAccumulatedEntries() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        let seed: [LiveCaptionEntry] = [
            LiveCaptionEntry(text: "hello", isFinal: true, startedAtMs: nil, endedAtMs: nil),
            LiveCaptionEntry(text: "world", isFinal: true, startedAtMs: nil, endedAtMs: nil),
        ]
        await actor.appendEntriesForTesting(seed)

        let entries = await actor.stop(saveTo: nil)
        XCTAssertEqual(entries, seed, "stop() must return accumulated entries verbatim.")

        let afterStop = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(afterStop, .stopped)
    }

    // MARK: - Stop on a fresh actor

    /// `stop()` on a freshly-created actor that never started must
    /// transition to `.stopped` and return an empty entry list.
    func testStopOnCreatedTransitionsDirectlyToStopped() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        let entries = await actor.stop(saveTo: nil)
        XCTAssertEqual(entries, [])
        let snapshot = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(snapshot, .stopped)
    }

    // MARK: - Stop is idempotent

    /// Calling `stop()` a second time must return the same entries
    /// and leave the lifecycle in `.stopped`.
    func testStopIsIdempotent() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        _ = await actor.stop(saveTo: nil)
        let snapshotAfterFirst = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(snapshotAfterFirst, .stopped)

        let entries = await actor.stop(saveTo: nil)
        XCTAssertEqual(entries, [])
        let snapshotAfterSecond = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(snapshotAfterSecond, .stopped)
    }

    // MARK: - Claim failure → reconnect → live

    /// `.live → .reconnecting → .live` when the claim fails once and
    /// then succeeds. The receive failure simulates a transient
    /// network drop; the actor must schedule a retry and recover.
    func testClaimFailureSchedulesReconnect() async {
        let connector = MockRealtimeSessionConnector()
        connector.claimFailures = 1
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            configuration: .init(reconnectDelays: [0.01])
        )

        await actor.start()

        // Drain through: first claim fails → reconnect scheduled →
        // second claim succeeds → live.
        try? await Task.sleep(nanoseconds: 200_000_000)

        let snapshot = await actor.lifecycleSnapshotForTesting()
        switch snapshot {
        case .live:
            break
        default:
            XCTFail("Expected .live after recovery, got \(snapshot)")
        }
        XCTAssertEqual(connector.claimCallCount, 2, "Claim must have been attempted twice (one failure + one success).")
    }

    // MARK: - Stop during reconnect

    /// `.reconnecting → .stopping → .stopped` when stop is invoked
    /// while a delayed retry is suspended. The pending re-claim must
    /// not fire.
    func testStopDuringReconnectAbortsRetry() async {
        let connector = MockRealtimeSessionConnector()
        connector.claimFailures = 1
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            // 200 ms delay: long enough to call stop() before the
            // retry fires, short enough to wait past it within the
            // test budget and assert the retry actually didn't fire.
            configuration: .init(reconnectDelays: [0.2])
        )

        await actor.start()
        // Wait until first claim has failed → lifecycle should be
        // .reconnecting now.
        await connector.waitForClaimResolved()
        try? await Task.sleep(nanoseconds: 30_000_000)

        let mid = await actor.lifecycleSnapshotForTesting()
        switch mid {
        case .reconnecting:
            break
        default:
            XCTFail("Expected .reconnecting after first failure, got \(mid)")
        }

        _ = await actor.stop(saveTo: nil)
        let afterStop = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(afterStop, .stopped)

        // Wait past the retry delay (200 ms) plus headroom; the retry
        // must NOT fire — the post-sleep guard inside scheduleReconnect
        // must observe `.stopped` and bail.
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(
            connector.claimCallCount, 1,
            "Stop during reconnect must prevent the retry from firing."
        )
        // And the lifecycle must still be `.stopped`, not resurrected
        // to `.claiming` by a stale retry.
        let final = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(
            final, .stopped,
            "Stale retry must not resurrect the lifecycle past .stopped."
        )
    }

    // MARK: - Stale receive — pattern match drops

    /// A late receive callback delivered against a stale socket must
    /// be discarded. Lifecycle stays on its current case; the stale
    /// socket has no influence on actor state.
    func testStaleReceiveOnRotatedSocketIsDropped() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            configuration: .init(reconnectDelays: [0.01])
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        // Capture the live identity before rotating: stale (socket,
        // generation) tuple we'll feed back to the receive-handler
        // seam after the rotation.
        guard let stale = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live identity before rotation.")
            return
        }

        // Rotate the socket by triggering a manual reconnect.
        await actor.reconnectNow()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let fresh = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live identity after rotation.")
            return
        }
        XCTAssertFalse(stale.socket === fresh.socket, "Reconnect must produce a new socket.")
        XCTAssertNotEqual(stale.generation, fresh.generation, "Reconnect must bump the generation.")

        let liveSnapshotBefore = await actor.lifecycleSnapshotForTesting()
        switch liveSnapshotBefore {
        case .live:
            break
        default:
            XCTFail("Expected .live after rotation, got \(liveSnapshotBefore)")
        }

        // 1) Stale SUCCESS: pattern-match guard must drop the message
        // and leave the lifecycle untouched.
        let afterStaleSuccess = await actor.simulateReceiveOutcomeForTesting(
            socket: stale.socket,
            generation: stale.generation,
            outcome: .success(.text("late-buffered"))
        )
        XCTAssertEqual(
            afterStaleSuccess, liveSnapshotBefore,
            "Stale receive (success) must not advance the lifecycle."
        )

        // 2) Stale FAILURE: must NOT schedule a reconnect on the
        // fresh socket. This is the production bug — a late buffered
        // failure on socket A used to bypass the identity guard and
        // tear down healthy socket B.
        let afterStaleFailure = await actor.simulateReceiveOutcomeForTesting(
            socket: stale.socket,
            generation: stale.generation,
            outcome: .failure(NSError(domain: "stale", code: 1))
        )
        XCTAssertEqual(
            afterStaleFailure, liveSnapshotBefore,
            "Stale receive (failure) must not tear down the fresh socket."
        )

        // 3) FRESH FAILURE: must transition the lifecycle to
        // .reconnecting — pins the happy path so the guard doesn't
        // accidentally suppress legitimate failures.
        _ = await actor.simulateReceiveOutcomeForTesting(
            socket: fresh.socket,
            generation: fresh.generation,
            outcome: .failure(NSError(domain: "fresh", code: 1))
        )
        let afterFreshFailure = await actor.lifecycleSnapshotForTesting()
        switch afterFreshFailure {
        case .reconnecting, .claiming, .live:
            break
        default:
            XCTFail("Fresh failure must drive reconnect path, got \(afterFreshFailure)")
        }
    }

    // MARK: - Multiple rapid reconnectNow() calls

    /// Two rapid `reconnectNow()` invocations must serialize through
    /// the actor's reentrancy. The second call observes whatever
    /// lifecycle case the first left and reacts accordingly — the
    /// invariant is that we never crash, never leak sockets, and the
    /// actor lands on `.live` afterward.
    func testRapidReconnectCallsSettleOnLive() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        async let a: Void = actor.reconnectNow()
        async let b: Void = actor.reconnectNow()
        _ = await (a, b)

        try? await Task.sleep(nanoseconds: 100_000_000)

        let snapshot = await actor.lifecycleSnapshotForTesting()
        switch snapshot {
        case .live:
            break
        default:
            XCTFail("Expected .live after rapid reconnect, got \(snapshot)")
        }
    }
}

// MARK: - Mock connector + socket

/// Test double for `RealtimeSessionConnector`. Records call counts so
/// tests can assert that stale operations don't reach the network.
final class MockRealtimeSessionConnector: RealtimeSessionConnector, @unchecked Sendable {
    private let lock = NSLock()

    private var _claimCallCount = 0
    private var _openSocketCallCount = 0
    private var _claimFailures: Int = 0
    private var _holdClaim = false
    private var _claimContinuations: [CheckedContinuation<Void, Never>] = []
    private var _claimResolvedWaiters: [CheckedContinuation<Void, Never>] = []
    private var _socketOpenedWaiters: [CheckedContinuation<Void, Never>] = []
    private var _claimResolvedCount = 0
    private var _socketOpenedCount = 0
    private var _waitingClaimResolvedTarget = 0
    private var _waitingSocketOpenedTarget = 0
    private var _lastIssuedSocket: MockRealtimeSocket?

    var claimCallCount: Int { lock.withLock { _claimCallCount } }
    var openSocketCallCount: Int { lock.withLock { _openSocketCallCount } }
    var lastIssuedSocket: MockRealtimeSocket? { lock.withLock { _lastIssuedSocket } }

    var claimFailures: Int {
        get { lock.withLock { _claimFailures } }
        set { lock.withLock { _claimFailures = newValue } }
    }
    var holdClaim: Bool {
        get { lock.withLock { _holdClaim } }
        set { lock.withLock { _holdClaim = newValue } }
    }

    func claimSession(
        mode: RealtimeLiveCaptionMode,
        language: String
    ) async throws -> RealtimeSessionClaim {
        let shouldFail: Bool = lock.withLock {
            _claimCallCount += 1
            if _claimFailures > 0 {
                _claimFailures -= 1
                return true
            }
            return false
        }

        if lock.withLock({ _holdClaim }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { _claimContinuations.append(continuation) }
            }
        }

        // Signal "claim resolved" waiters BEFORE returning, since
        // `wait` ordering matters for the call-count assertions.
        lock.withLock {
            _claimResolvedCount += 1
            let pending = _claimResolvedWaiters
            _claimResolvedWaiters.removeAll()
            for waiter in pending { waiter.resume() }
        }

        if shouldFail {
            throw NSError(domain: "MockConnector", code: 1, userInfo: nil)
        }

        return RealtimeSessionClaim(
            sessionId: "mock-session-\(claimCallCount)",
            websocketURL: URL(string: "wss://mock.invalid/ws")!,
            token: "mock-token",
            tokenType: "Bearer"
        )
    }

    func openSocket(for claim: RealtimeSessionClaim) async throws -> RealtimeSocket {
        let socket = MockRealtimeSocket()
        lock.withLock {
            _openSocketCallCount += 1
            _lastIssuedSocket = socket
            _socketOpenedCount += 1
            let pending = _socketOpenedWaiters
            _socketOpenedWaiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
        return socket
    }

    // MARK: - Test scaffolding

    /// Wait until the next claim attempt resolves (success or
    /// failure). One claim attempt = one resolution; called once.
    func waitForClaimResolved() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldResolveImmediately = lock.withLock { () -> Bool in
                if _claimResolvedCount > _waitingClaimResolvedTarget {
                    _waitingClaimResolvedTarget += 1
                    return true
                }
                _waitingClaimResolvedTarget += 1
                _claimResolvedWaiters.append(continuation)
                return false
            }
            if shouldResolveImmediately {
                continuation.resume()
            }
        }
    }

    /// Wait until the next socket is opened (one open per call).
    func waitForSocketOpened() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldResolveImmediately = lock.withLock { () -> Bool in
                if _socketOpenedCount > _waitingSocketOpenedTarget {
                    _waitingSocketOpenedTarget += 1
                    return true
                }
                _waitingSocketOpenedTarget += 1
                _socketOpenedWaiters.append(continuation)
                return false
            }
            if shouldResolveImmediately {
                continuation.resume()
            }
        }
    }

    /// Release any claim suspended by `holdClaim = true`.
    func releaseClaim() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            _holdClaim = false
            let waiters = _claimContinuations
            _claimContinuations.removeAll()
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }
}

final class MockRealtimeSocket: RealtimeSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var receivedMessages: [RealtimeSocketMessage] = []
    private var pendingReceiveWaiters: [CheckedContinuation<RealtimeSocketMessage, Error>] = []
    private var _sentTexts: [String] = []
    private var _cancelled = false
    private var _cancelCode: Int = 0
    private var _cancelReason: Data?
    private var _pingHandler: (@Sendable () async throws -> Void)?
    private var _pingCallCount = 0
    private var _sendHandler: (@Sendable (String) async throws -> Void)?
    private var _closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var _autoSignalCloseOnCancel = true
    /// When set, `receive()` blocks until cancelled instead of throwing
    /// `CancellationError` immediately. Used by stall-watchdog tests
    /// where we don't want the receive loop to short-circuit our
    /// scripted state transitions.

    var sentTexts: [String] { lock.withLock { _sentTexts } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    var cancelCode: Int { lock.withLock { _cancelCode } }
    var cancelReason: Data? { lock.withLock { _cancelReason } }
    var pingCallCount: Int { lock.withLock { _pingCallCount } }

    /// Server-issued close code surfaced through the `closeCode` /
    /// `closeReason` protocol points. Tests use `simulateCloseFromServer`
    /// to set these alongside throwing the next pending `receive()`.
    private var _closeCode: Int = 0
    private var _closeReason: Data?
    var closeCode: Int { lock.withLock { _closeCode } }
    var closeReason: Data? { lock.withLock { _closeReason } }

    func send(text: String) async throws {
        let handler: (@Sendable (String) async throws -> Void)? = lock.withLock { _sendHandler }
        if let handler {
            try await handler(text)
        }
        lock.withLock { _sentTexts.append(text) }
    }

    /// Install a send handler so tests can script send failures. Called
    /// BEFORE the text is appended to `sentTexts`, so a throwing handler
    /// prevents the text from being recorded as sent.
    func setSendHandler(_ handler: (@Sendable (String) async throws -> Void)?) {
        lock.withLock { _sendHandler = handler }
    }

    /// Control whether `cancel(code:reason:)` automatically signals
    /// `waitForClose()`. Defaults to true so most tests get the same
    /// "cancel synchronously delivers a close" behaviour the production
    /// adapter provides. Tests that want to model a wedged close
    /// handshake (Finding #6) flip this to false and call
    /// `simulateCloseSignal()` explicitly.
    func setAutoSignalCloseOnCancel(_ enabled: Bool) {
        lock.withLock { _autoSignalCloseOnCancel = enabled }
    }

    /// Manually signal `waitForClose()` continuations. Used by Finding
    /// #6 tests to model a delayed close-handshake response.
    func simulateCloseSignal() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            let pending = _closeWaiters
            _closeWaiters.removeAll()
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitForClose() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldResolveImmediately = lock.withLock { () -> Bool in
                if _cancelled && _autoSignalCloseOnCancel {
                    return true
                }
                _closeWaiters.append(continuation)
                return false
            }
            if shouldResolveImmediately {
                continuation.resume()
            }
        }
    }

    func sendPing() async throws {
        let handler: (@Sendable () async throws -> Void)? = lock.withLock {
            _pingCallCount += 1
            return _pingHandler
        }
        if let handler {
            try await handler()
        }
    }

    /// Install a ping handler so tests can script a successful pong, a
    /// throwing ping, or a long-suspending ping. Default behaviour
    /// (`nil`) is "ping succeeds immediately".
    func setPingHandler(_ handler: (@Sendable () async throws -> Void)?) {
        lock.withLock { _pingHandler = handler }
    }

    func receive() async throws -> RealtimeSocketMessage {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RealtimeSocketMessage, Error>) in
            lock.lock()
            if !receivedMessages.isEmpty {
                let next = receivedMessages.removeFirst()
                lock.unlock()
                continuation.resume(returning: next)
                return
            }
            pendingReceiveWaiters.append(continuation)
            lock.unlock()
        }
    }

    func cancel(code: Int, reason: Data?) {
        var closeWaitersToResume: [CheckedContinuation<Void, Never>] = []
        let waiters: [CheckedContinuation<RealtimeSocketMessage, Error>] = lock.withLock {
            _cancelled = true
            _cancelCode = code
            _cancelReason = reason
            let pending = pendingReceiveWaiters
            pendingReceiveWaiters.removeAll()
            if _autoSignalCloseOnCancel {
                closeWaitersToResume = _closeWaiters
                _closeWaiters.removeAll()
            }
            return pending
        }
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
        }
        for waiter in closeWaitersToResume {
            waiter.resume()
        }
    }

    /// Push a scripted message so the next pending `receive()` call
    /// returns it. Used by stale-receive tests to deliver a frame
    /// against a (now stale) socket.
    func enqueueScriptedMessage(_ message: RealtimeSocketMessage) {
        let resolved: CheckedContinuation<RealtimeSocketMessage, Error>? = lock.withLock {
            if !pendingReceiveWaiters.isEmpty {
                return pendingReceiveWaiters.removeFirst()
            }
            receivedMessages.append(message)
            return nil
        }
        resolved?.resume(returning: message)
    }

    /// Simulate a server-issued close. Throws the next pending
    /// `receive()` with an error and snapshots the close code / reason
    /// so the actor's terminal-code logic can pick them up via the
    /// `closeCode` / `closeReason` protocol points.
    func simulateCloseFromServer(code: Int, reason: Data? = nil, error: Error) {
        var closeWaitersToResume: [CheckedContinuation<Void, Never>] = []
        let waiters: [CheckedContinuation<RealtimeSocketMessage, Error>] = lock.withLock {
            _closeCode = code
            _closeReason = reason
            let pending = pendingReceiveWaiters
            pendingReceiveWaiters.removeAll()
            closeWaitersToResume = _closeWaiters
            _closeWaiters.removeAll()
            return pending
        }
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
        for waiter in closeWaitersToResume {
            waiter.resume()
        }
    }
}

// MARK: - NSLock helper

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
