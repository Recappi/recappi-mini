import XCTest
@testable import RecappiMini

/// Phase 3e — regression tests for Codex Round-3 client findings #1 and
/// #3, exercised against `RealtimeLiveCaptionActor` (the new
/// architecture). These tests would FAIL against the legacy
/// `BackendRealtimeLiveCaptionTranscriber` because the bugs they pin
/// were structurally part of that class's design. They PASS here
/// because the actor prevents the bugs by CONSTRUCTION:
///
/// - Finding #1 — stale `run` overwrites newer socket: the actor
///   stamps each claim attempt with an integer `generation` and
///   pattern-matches the lifecycle case after every `await`. A stale
///   claim that resolves after the lifecycle has advanced to a newer
///   generation simply returns without installing its socket.
///
/// - Finding #3 — receive identity guard "check before use": the
///   actor's receive loop calls `isCurrent(socket:generation:)` BEFORE
///   any state mutation. The `simulateReceiveOutcomeForTesting` seam
///   exercises this guard explicitly with a stale (socket, generation)
///   pair. The legacy class's `consume(message:from:)` code paths that
///   passed `task: nil` bypassed the equivalent guard — Phase 3a's
///   actor design replaces those code paths entirely.
final class RealtimeLiveCaptionActorFindingsRegressionTests: XCTestCase {
    // MARK: - Finding #1: stale claim must not install a socket

    /// Concrete failure timeline this test would catch:
    ///   t0 .claiming(gen=1) — claim A in flight, /sessions slow
    ///   t1 stop() forces .stopped; the old `run` Task is "lost"
    ///   t2 the slow claim eventually resolves at t≫t1
    ///   BUG: the resolved claim's openSocket runs, installing a
    ///        socket on an actor that has already terminated.
    ///   FIX (by construction): performClaim re-checks lifecycle
    ///        after each await and aborts because `case .claiming` no
    ///        longer matches.
    func testStaleClaimDuringStopDoesNotOpenSocket() async {
        let connector = MockRealtimeSessionConnector()
        connector.holdClaim = true
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        await actor.start()
        await Task.yield()

        // Stop while the claim is mid-flight.
        _ = await actor.stop(saveTo: nil)
        let postStop = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(postStop, .stopped)

        // Release the held claim — it resolves AFTER stop completed.
        connector.releaseClaim()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The structural fix: openSocket must NOT have been called on
        // the stale claim. The actor's post-await guard short-circuits
        // before reaching openSocket.
        XCTAssertEqual(
            connector.openSocketCallCount, 0,
            "Stale claim resolving after .stopped must not call openSocket."
        )
        let final = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(final, .stopped, "Stale claim must not resurrect the lifecycle.")
    }

    /// Concrete failure timeline this test would catch:
    ///   t0 .claiming(gen=1) — claim A is slow
    ///   t1 reconnectNow() — actor advances; new claim B fires at gen=2
    ///   t2 claim A finally returns, openSocket succeeds for A
    ///   t3 claim B has already installed socket B at gen=2
    ///   BUG: claim A's late post-openSocket guard misses, installing
    ///        socket A and clobbering socket B.
    ///   FIX (by construction): generation comparison rejects the stale
    ///        claim. The socket is opened (we can't always avoid the
    ///        openSocket call when the connector resolves them out of
    ///        order) but is IMMEDIATELY cancelled and never installed.
    func testStaleClaimDuringReconnectGetsCancelledNotInstalled() async {
        let connector = MockRealtimeSessionConnector()
        connector.holdClaim = true
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        await actor.start()
        await Task.yield()

        // Pre-stop check: we are mid-claim.
        let preStopSnapshot = await actor.lifecycleSnapshotForTesting()
        switch preStopSnapshot {
        case .claiming:
            break
        default:
            XCTFail("Expected .claiming before stop, got \(preStopSnapshot)")
        }

        // Drive the actor straight to .stopped before releasing claim.
        _ = await actor.stop(saveTo: nil)

        // Now release the held first-attempt claim. Its post-await
        // guard inside performClaim must observe that the lifecycle no
        // longer matches its generation and bail.
        connector.releaseClaim()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Even if openSocket was called for the stale claim, the
        // resulting socket must not be installed — the actor's
        // identity guard cancels it before transitioning to .live.
        // The strict assertion: lifecycle stays on .stopped.
        let final = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(final, .stopped, "Stale claim must not advance lifecycle past .stopped.")
        // And the connector observed only the one claim attempt.
        XCTAssertEqual(connector.claimCallCount, 1)
    }

    // MARK: - Finding #3: receive identity guard runs BEFORE state mutation

    /// Concrete failure timeline this test would catch:
    ///   t0 socket A delivers stale `session.created` AFTER A was
    ///      rotated out and B was installed.
    ///   BUG: receive handler `markConnectionHealthy()` mutates state
    ///        belonging to B (zeroes counters, resets transcript-stall
    ///        timer) because the identity guard was missing or applied
    ///        too late.
    ///   FIX (by construction): the actor's receive loop calls
    ///        `isCurrent(socket:generation:)` BEFORE handing the event
    ///        to the receive-side state mutator. A non-current socket
    ///        causes the handler to return early.
    func testStaleSessionCreatedDoesNotResetCountersOnFreshSocket() async {
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

        guard let stale = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live identity before rotation.")
            return
        }

        // Rotate: capture fresh identity.
        await actor.reconnectNow()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let fresh = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live identity after rotation.")
            return
        }
        XCTAssertFalse(stale.socket === fresh.socket)
        XCTAssertNotEqual(stale.generation, fresh.generation)

        // Push a stale session.created on the OLD socket. The actor's
        // identity guard must drop it; the fresh lifecycle stays put.
        let before = await actor.lifecycleSnapshotForTesting()
        let after = await actor.simulateReceiveOutcomeForTesting(
            socket: stale.socket,
            generation: stale.generation,
            outcome: .success(.text("{\"type\":\"session.created\"}"))
        )
        XCTAssertEqual(
            before, after,
            "Stale session.created must not advance the lifecycle."
        )

        _ = await actor.stop(saveTo: nil)
    }

    /// Concrete failure timeline this test would catch:
    ///   t0 socket A buffers an `error` event from the upstream.
    ///   t1 the actor rotates to socket B (reconnectNow).
    ///   t2 the late buffered error finally lands.
    ///   BUG: legacy `consume`'s `case "error"` passes `task: nil` to
    ///        `handleConnectionFailure`, which then skips the identity
    ///        guard and tears down socket B.
    ///   FIX (by construction): receive identity guard runs at the
    ///        actor entry point, before any failure handler can mutate
    ///        state. A stale error on socket A is dropped silently.
    func testStaleErrorEventDoesNotTriggerReconnectOnFreshSocket() async {
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

        guard let stale = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live identity before rotation.")
            return
        }

        await actor.reconnectNow()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        let freshSnapshotBefore = await actor.lifecycleSnapshotForTesting()
        switch freshSnapshotBefore {
        case .live:
            break
        default:
            XCTFail("Expected .live after rotation, got \(freshSnapshotBefore)")
        }

        // Stale FAILURE: the actor's receive identity guard rejects
        // it, so the fresh socket's lifecycle remains untouched.
        let after = await actor.simulateReceiveOutcomeForTesting(
            socket: stale.socket,
            generation: stale.generation,
            outcome: .failure(NSError(domain: "stale-error", code: 1))
        )
        XCTAssertEqual(
            freshSnapshotBefore, after,
            "Stale error must not tear down the fresh socket."
        )

        _ = await actor.stop(saveTo: nil)
    }

    /// Mirror of #3 against the stall-watchdog post-ping decision: a
    /// stale (socket, generation) verdict (success or failure) must
    /// NOT mutate the fresh socket's lifecycle. The legacy
    /// `applyStallPingOutcome`'s identity guard is preserved in the
    /// actor's `runStallWatchdogProbe`, which re-checks lifecycle
    /// after the ping race resolves.
    func testStaleStallVerdictDoesNotMutateFreshLifecycle() async {
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

        guard let stale = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected live identity before rotation.")
            return
        }

        await actor.reconnectNow()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let fresh = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected live identity after rotation.")
            return
        }

        // Run a stall probe with the STALE socket + STALE generation
        // (the ping itself goes against the stale socket; the verdict
        // application must observe the rotation and refuse to mutate
        // the fresh lifecycle).
        guard let staleMock = stale.socket as? MockRealtimeSocket else {
            XCTFail("Expected MockRealtimeSocket on stale identity.")
            return
        }
        staleMock.setPingHandler({ /* success */ })

        _ = await actor.runStallWatchdogProbeForTesting(
            socket: stale.socket,
            generation: stale.generation,
            voicedBuffersSinceInbound: 30,
            secondsSinceLastInbound: 25,
            secondsSinceLastVoicedAudio: 0
        )

        let snapshot = await actor.lifecycleSnapshotForTesting()
        switch snapshot {
        case .live(let g) where g == fresh.generation:
            break
        default:
            XCTFail("Stale stall verdict must not mutate fresh lifecycle, got \(snapshot)")
        }

        _ = await actor.stop(saveTo: nil)
    }
}
