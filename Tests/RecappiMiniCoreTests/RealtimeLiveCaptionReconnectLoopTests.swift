import XCTest
@testable import RecappiMini

/// Regression tests for the never-ending realtime reconnect loop.
///
/// Two independent defects are pinned here:
///  - A permanent claim rejection (402, the unified-minutes cap) used to
///    fall into `scheduleReconnect` like any transient failure, so a
///    quota-exhausted user re-claimed forever behind a "Reconnecting…"
///    panel that could never clear.
///  - Socket-level failures used to pass a literal `attempt: 1` into
///    `scheduleReconnect`, pinning the ladder at `reconnectDelays[1]`
///    forever instead of escalating.
final class RealtimeLiveCaptionReconnectLoopTests: XCTestCase {
    private static let quotaExhaustedMessage = """
        Monthly minutes quota exhausted (120 of 120 minutes used on the free plan; \
        live transcription/translation and batch transcription share this pool). \
        Quota resets on 2026-10-01T00:00:00.000Z.
        """

    // MARK: - Permanent vs. retryable classification

    func testOnly402ClassifiesAsPermanentClaimRejection() {
        XCTAssertTrue(
            RealtimeLiveCaptionActor.isPermanentClaimRejection(
                RecappiAPIError.http(statusCode: 402, message: Self.quotaExhaustedMessage)
            ),
            "402 (unified minutes cap) is period-scoped and cannot be resolved by retrying."
        )
        // Every other status the realtime claim endpoint returns has an
        // explicitly retryable contract: 401 is answered by the next
        // cycle's fresh token (each reconnect re-claims), 409 says
        // "re-claim required", 429 is rate-limit cooldown, 503 says
        // "Retry in a few seconds".
        for status in [401, 409, 429, 500, 503] {
            XCTAssertFalse(
                RealtimeLiveCaptionActor.isPermanentClaimRejection(
                    RecappiAPIError.http(statusCode: status, message: "transient")
                ),
                "\(status) must stay retryable."
            )
        }
        XCTAssertFalse(
            RealtimeLiveCaptionActor.isPermanentClaimRejection(NSError(domain: "Net", code: -1009)),
            "A transport error carries no HTTP status and must stay retryable."
        )
    }

    func testClaimRejectionMessagePassesServerTextThrough() {
        XCTAssertEqual(
            RealtimeLiveCaptionActor.claimRejectionMessage(
                RecappiAPIError.http(statusCode: 402, message: Self.quotaExhaustedMessage)
            ),
            Self.quotaExhaustedMessage
        )
        XCTAssertEqual(
            RealtimeLiveCaptionActor.claimRejectionMessage(
                RecappiAPIError.http(statusCode: 402, message: "   ")
            ),
            "Live captions unavailable.",
            "A blank server message must fall back to a usable line."
        )
    }

    // MARK: - Part A — a permanent 402 stops the loop

    /// A 402 claim rejection must terminate the lifecycle after ONE
    /// claim: no retry, `.stopped`, and an `.unavailable` snapshot
    /// carrying the server's own quota text. Against the pre-fix actor
    /// `claimCallCount` grows without bound.
    func testPermanentClaimRejectionStopsTheReconnectLoop() async {
        let connector = MockRealtimeSessionConnector()
        connector.claimFailures = 99
        connector.claimFailureError = RecappiAPIError.http(
            statusCode: 402,
            message: Self.quotaExhaustedMessage
        )
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .translation(targetLanguage: "zh"),
            configuration: .init(reconnectDelays: [0.01])
        )
        let stream = await actor.captionSnapshots()
        let recorder = SnapshotRecorder()
        let consumer = Task {
            for await snapshot in stream {
                recorder.append(snapshot)
            }
        }

        await actor.start()
        await connector.waitForClaimResolved()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            connector.claimCallCount,
            1,
            "A 402 claim rejection must not be retried — the quota only resets with the billing period."
        )
        let lifecycle = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(lifecycle, .stopped, "A permanent rejection must terminate the lifecycle.")

        let unavailable = recorder.snapshots.first { $0.phase == .unavailable }
        XCTAssertNotNil(unavailable, "Expected an .unavailable snapshot. got: \(recorder.snapshots.map(\.phase))")
        XCTAssertEqual(unavailable?.message, Self.quotaExhaustedMessage)
        XCTAssertFalse(
            recorder.snapshots.contains { $0.phase == .reconnecting },
            "A permanent rejection must never publish .reconnecting."
        )

        consumer.cancel()
        _ = await actor.stop(saveTo: nil)
    }

    /// The regression guard against over-terminating: 503 ("Retry in a
    /// few seconds") must keep the ladder running.
    func testRetryableClaimRejectionKeepsRetrying() async {
        let connector = MockRealtimeSessionConnector()
        connector.claimFailures = 99
        connector.claimFailureError = RecappiAPIError.http(
            statusCode: 503,
            message: "Subscription is renewing — quota window is between periods. Retry in a few seconds."
        )
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            configuration: .init(reconnectDelays: [0.01])
        )

        await actor.start()
        await connector.waitForClaimResolved()

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline && connector.claimCallCount < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertGreaterThanOrEqual(
            connector.claimCallCount,
            2,
            "503 is an explicitly transient contract and must keep retrying."
        )
        let lifecycle = await actor.lifecycleSnapshotForTesting()
        XCTAssertNotEqual(lifecycle, .stopped, "A retryable rejection must not terminate the lifecycle.")

        _ = await actor.stop(saveTo: nil)
    }

    /// 409 ("re-claim required") likewise stays on the ladder — every
    /// reconnect mints a fresh claim, which is exactly what the server
    /// asks for.
    func testConflictClaimRejectionKeepsRetrying() async {
        let connector = MockRealtimeSessionConnector()
        connector.claimFailures = 99
        connector.claimFailureError = RecappiAPIError.http(
            statusCode: 409,
            message: "Realtime session superseded by a newer claim; re-claim required."
        )
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            configuration: .init(reconnectDelays: [0.01])
        )

        await actor.start()
        await connector.waitForClaimResolved()

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline && connector.claimCallCount < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertGreaterThanOrEqual(connector.claimCallCount, 2)
        let lifecycle = await actor.lifecycleSnapshotForTesting()
        XCTAssertNotEqual(lifecycle, .stopped)

        _ = await actor.stop(saveTo: nil)
    }

    // MARK: - Part B — the socket ladder climbs

    /// Three consecutive born-dead sockets must schedule their retries
    /// at climbing ladder indices (1 → 2 → 3). Against the pre-fix actor
    /// every one of them reports `attempt: 1`, i.e. `delays[1]` forever.
    func testConsecutiveSocketFailuresEscalateTheReconnectLadder() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            // Index 0 is never used by the socket path (the first
            // socket failure already reports attempt 1); the rest are
            // long enough to observe `.reconnecting` before it fires.
            configuration: .init(reconnectDelays: [0.01, 0.20, 0.20, 0.20, 0.20])
        )

        await actor.start()

        var observedAttempts: [Int] = []
        for _ in 0..<3 {
            await connector.waitForSocketOpened()
            // Wait for the receive loop to be the thing holding the
            // socket, then kill it with a non-terminal close code.
            guard let socket = connector.lastIssuedSocket else {
                XCTFail("Expected an issued socket.")
                return
            }
            socket.simulateCloseFromServer(
                code: 1006,
                reason: nil,
                error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
            )

            let deadline = Date().addingTimeInterval(1.0)
            var attempt: Int?
            while Date() < deadline {
                if case .reconnecting(_, let observed) = await actor.lifecycleSnapshotForTesting() {
                    attempt = observed
                    break
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let attempt else {
                XCTFail("Expected .reconnecting after a socket failure. got: \(observedAttempts)")
                return
            }
            observedAttempts.append(attempt)
        }

        XCTAssertEqual(
            observedAttempts,
            [1, 2, 3],
            "Repeated socket failures must climb the reconnect ladder instead of pinning at delays[1]."
        )

        _ = await actor.stop(saveTo: nil)
    }

    /// One delivered frame is NOT health. Every upstream emits
    /// `session.created` / `transcription_session.created` the instant
    /// the socket opens, so treating the first frame as "this socket was
    /// healthy" resets the streak on every single connection and pins
    /// the ladder at `delays[1]` (= 2 s) forever — exactly the
    /// production signature (endless 2 s reconnect churn) the ladder
    /// exists to break.
    ///
    /// Fully deterministic: the frame is handed to a receive loop that
    /// is provably parked inside `receive()`, and the close is only
    /// scripted once the loop has re-entered `receive()`, which proves
    /// the frame was consumed.
    func testDeliveredFrameAloneDoesNotResetTheSocketFailureStreak() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            configuration: .init(reconnectDelays: [0.01, 0.20, 0.20, 0.20, 0.20])
        )

        await actor.start()

        // Socket 1: dies without ever delivering a frame → attempt 1.
        guard let first = await Self.nextParkedSocket(from: connector) else {
            XCTFail("Expected a first socket parked on receive().")
            return
        }
        Self.killSocket(first)
        let firstAttempt = await Self.awaitReconnectAttempt(actor)
        XCTAssertEqual(firstAttempt, 1)

        // Socket 2: delivers one frame, then dies young.
        guard let second = await Self.nextParkedSocket(from: connector) else {
            XCTFail("Expected a second socket parked on receive().")
            return
        }
        second.enqueueScriptedMessage(.text(#"{"type":"transcription_session.created"}"#))
        // Entry #2 into `receive()` proves the frame above was consumed.
        guard await second.waitForReceiveEntered(atLeast: 2) else {
            XCTFail(
                "Timed out waiting for the receive loop to re-enter receive() after the scripted frame; the frame was never consumed, so the streak assertion below would be meaningless."
            )
            return
        }
        Self.killSocket(second)
        let secondAttempt = await Self.awaitReconnectAttempt(actor)

        XCTAssertEqual(
            secondAttempt,
            2,
            "A socket that received a frame and then died young was never healthy — the ladder must keep climbing."
        )

        _ = await actor.stop(saveTo: nil)
    }

    /// A socket that STAYED UP past `healthySocketUptime` was a working
    /// session, so the next failure restarts the ladder at 1 instead of
    /// inheriting the previous streak.
    ///
    /// Deterministic: the open instant is backdated through a seam
    /// rather than waiting out the real 30 s threshold, so no wall-clock
    /// race decides the assertion.
    func testSocketThatStayedUpPastHealthyThresholdResetsTheLadder() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            configuration: .init(reconnectDelays: [0.01, 0.20, 0.20, 0.20, 0.20])
        )

        await actor.start()

        // Two short-lived sockets climb the ladder to 2.
        for expected in [1, 2] {
            guard let socket = await Self.nextParkedSocket(from: connector) else {
                XCTFail("Expected a socket parked on receive().")
                return
            }
            Self.killSocket(socket)
            let attempt = await Self.awaitReconnectAttempt(actor)
            XCTAssertEqual(attempt, expected)
        }

        // Third socket looks like it has been live longer than the
        // healthy-uptime threshold before it drops.
        guard let longLived = await Self.nextParkedSocket(from: connector) else {
            XCTFail("Expected a third socket parked on receive().")
            return
        }
        let backdated = await actor.backdateLiveOpenedAtForTesting(
            by: RealtimeLiveCaptionActor.healthySocketUptime + 1
        )
        XCTAssertTrue(backdated, "Expected a .live open instant to backdate.")
        Self.killSocket(longLived)
        let afterHealthy = await Self.awaitReconnectAttempt(actor)

        XCTAssertEqual(
            afterHealthy,
            1,
            "A socket that stayed up past the healthy threshold must restart the ladder."
        )

        _ = await actor.stop(saveTo: nil)
    }


    /// A socket does not have to FAIL to be retired. The user's manual
    /// Reconnect takes a healthy socket out of service without ever
    /// touching the socket-failure path, so a reset that lives only on
    /// that path leaves the streak intact: two old blips would still
    /// charge the next blip `delays[3]` after hours of healthy recording.
    func testHealthySocketRetiredByManualReconnectResetsTheLadder() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            configuration: .init(reconnectDelays: [0.01, 0.20, 0.20, 0.20, 0.20])
        )

        await actor.start()

        // Two short-lived sockets climb the ladder to 2.
        for expected in [1, 2] {
            guard let socket = await Self.nextParkedSocket(from: connector) else {
                XCTFail("Expected a socket parked on receive().")
                return
            }
            Self.killSocket(socket)
            let attempt = await Self.awaitReconnectAttempt(actor)
            XCTAssertEqual(attempt, expected)
        }

        // A long, healthy session that the user then reconnects by hand.
        guard await Self.nextParkedSocket(from: connector) != nil else {
            XCTFail("Expected a third socket parked on receive().")
            return
        }
        let backdated = await actor.backdateLiveOpenedAtForTesting(
            by: RealtimeLiveCaptionActor.healthySocketUptime + 1
        )
        XCTAssertTrue(backdated, "Expected a .live open instant to backdate.")
        await actor.reconnectNow()

        // The replacement socket dies young: the streak it inherited from
        // the healthy socket's retirement is the whole assertion.
        guard let replacement = await Self.nextParkedSocket(from: connector) else {
            XCTFail("Expected a socket parked on receive() after the manual reconnect.")
            return
        }
        Self.killSocket(replacement)
        let afterManualReconnect = await Self.awaitReconnectAttempt(actor)

        XCTAssertEqual(
            afterManualReconnect,
            1,
            "A socket that lived past the healthy threshold must clear the streak when the user retires it by hand, not only when it fails."
        )

        _ = await actor.stop(saveTo: nil)
    }

    /// Same invariant on the planned ~20-minute age rotation: nothing
    /// failed, we deliberately retire a socket that carried a working
    /// session, so the ladder must start over at 1 on the next blip.
    func testHealthySocketRetiredByAgeRotationResetsTheLadder() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            configuration: .init(
                reconnectDelays: [0.01, 0.20, 0.20, 0.20, 0.20],
                // Shorter than `healthySocketUptime`, so ONE backdate
                // makes the live socket both healthy and old enough to
                // rotate. Until that backdate lands the age gate cannot
                // fire, which is what keeps this deterministic.
                proactiveSessionRotationInterval: RealtimeLiveCaptionActor.healthySocketUptime - 5
            )
        )
        await actor.setStallWatchdogIntervalForTesting(0.01)

        await actor.start()

        for expected in [1, 2] {
            guard let socket = await Self.nextParkedSocket(from: connector) else {
                XCTFail("Expected a socket parked on receive().")
                return
            }
            Self.killSocket(socket)
            let attempt = await Self.awaitReconnectAttempt(actor)
            XCTAssertEqual(attempt, expected)
        }

        guard await Self.nextParkedSocket(from: connector) != nil else {
            XCTFail("Expected a third socket parked on receive().")
            return
        }
        let backdated = await actor.backdateLiveOpenedAtForTesting(
            by: RealtimeLiveCaptionActor.healthySocketUptime + 1
        )
        XCTAssertTrue(backdated, "Expected a .live open instant to backdate.")

        // The next watchdog tick sees the backdated age and rotates.
        guard let rotated = await Self.nextParkedSocket(from: connector) else {
            XCTFail("Expected a rotated socket parked on receive().")
            return
        }
        Self.killSocket(rotated)
        let afterRotation = await Self.awaitReconnectAttempt(actor)

        XCTAssertEqual(
            afterRotation,
            1,
            "A socket that lived past the healthy threshold must clear the streak when the age rotation retires it."
        )

        _ = await actor.stop(saveTo: nil)
    }

    // MARK: - Helpers

    /// Wait for the next socket to be issued AND for its receive loop to
    /// park inside `receive()`. Returning only once the loop is parked
    /// removes the startup race that a bare `Task.sleep` used to paper
    /// over: the mock drains its queued close error before its message
    /// queue, so a frame scripted too early is silently overtaken.
    private static func nextParkedSocket(
        from connector: MockRealtimeSessionConnector,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> MockRealtimeSocket? {
        await connector.waitForSocketOpened()
        guard let socket = connector.lastIssuedSocket else { return nil }
        guard await socket.waitForReceiveEntered(atLeast: 1) else {
            XCTFail(
                "Timed out waiting for socket #\(connector.openSocketCallCount)'s receive loop to park inside receive().",
                file: file,
                line: line
            )
            return nil
        }
        return socket
    }

    private static func killSocket(_ socket: MockRealtimeSocket) {
        socket.simulateCloseFromServer(
            code: 1006,
            reason: nil,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        )
    }

    /// Poll for the `.reconnecting` attempt index. The deadline only
    /// bounds a failure — a slow machine reports nil and fails loudly,
    /// it never flips the assertion to a wrong-but-passing value.
    ///
    /// Missing the `.reconnecting` window (it lasts one reconnect delay,
    /// 200 ms here) and reading the wrong ladder index are two different
    /// bugs, so a miss names itself here instead of surfacing as a bare
    /// `("nil") is not equal to ("Optional(1)")` at the call site.
    private static func awaitReconnectAttempt(
        _ actor: RealtimeLiveCaptionActor,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastObserved = "none"
        while Date() < deadline {
            let snapshot = await actor.lifecycleSnapshotForTesting()
            if case .reconnecting(_, let observed) = snapshot {
                return observed
            }
            lastObserved = String(describing: snapshot)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail(
            "Never observed .reconnecting within \(timeout)s: the 5 ms poll missed the window, "
            + "or no reconnect was scheduled at all. Last lifecycle seen: \(lastObserved). "
            + "The ladder attempt index could NOT be sampled — this is a missed window, not a wrong index.",
            file: file,
            line: line
        )
        return nil
    }
}
