import XCTest
@testable import RecappiMini

/// Regression tests for the 6 client-side findings (#5..#10) on
/// `RealtimeLiveCaptionActor`. Each test pins a concrete behaviour
/// that the legacy `BackendRealtimeLiveCaptionTranscriber` provided
/// but didn't make it across the actor refactor. The tests would FAIL
/// against an actor missing the fix; they pass once the corresponding
/// behaviour is restored.
final class RealtimeLiveCaptionActorClientFindingsTests: XCTestCase {
    // MARK: - Finding #7 — Stall watchdog must run on a schedule

    /// On transition into `.live`, the actor must spawn a recurring
    /// watchdog task that probes the socket while it's quiet. With a
    /// small DEBUG interval and the threshold pre-fed via a test seam,
    /// a `sendPing()` must be observed within a short window.
    func testWatchdogTaskFiresPingOnSchedule() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        // Run the watchdog very frequently and consider the session
        // stalled immediately (the rules normally require seconds /
        // many voiced frames).
        await actor.setStallWatchdogIntervalForTesting(0.01)
        await actor.setStallWatchdogThresholdsForTesting(
            voicedBuffers: 0,
            secondsSinceLastInbound: 0
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        // Wait up to 1s for the watchdog to fire at least one ping.
        let deadline = Date().addingTimeInterval(1.0)
        var pings = 0
        while Date() < deadline {
            if let socket = connector.lastIssuedSocket {
                pings = socket.pingCallCount
                if pings >= 1 { break }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertGreaterThanOrEqual(
            pings, 1,
            "Watchdog must invoke sendPing() on schedule after .live."
        )

        _ = await actor.stop(saveTo: nil)
    }

    // MARK: - Finding #9 — Ping timeout must observe cancellation

    /// When `sendPing()` does not resolve before the timeout
    /// (half-open socket), the watchdog's race-against-timeout must
    /// NOT hang waiting for the dead ping. With a short ping timeout,
    /// the probe must return (with `pingFailedAndReconnected` since
    /// the timeout arm wins) within a small window — not deadlock
    /// waiting for `sendPing()`.
    func testStallProbeReturnsWhenPingNeverResolves() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            // Trim the reconnect delay too: after the (failed) ping
            // the probe calls `scheduleReconnect`, which sleeps for
            // `reconnectDelays[0]` before retrying. Tests that
            // measure the probe's own wall-clock can't pay for a 10
            // second retry delay.
            configuration: .init(reconnectDelays: [0.05])
        )

        // Drop the ping timeout so the timeout arm fires fast.
        await actor.setStallPingTimeoutForTesting(0.05)

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let live = await actor.currentLiveIdentityForTesting(),
              let mock = live.socket as? MockRealtimeSocket else {
            XCTFail("Expected MockRealtimeSocket on live.")
            return
        }
        // Install a ping handler that will not complete within the
        // probe timeout — simulating a half-open socket where the pong
        // callback never arrives. Use cancellation-aware sleep rather
        // than a deliberately leaked checked continuation, otherwise
        // the test itself emits Swift continuation-misuse warnings.
        mock.setPingHandler({
            try await Task.sleep(nanoseconds: 60_000_000_000)
        })

        let start = Date()
        let outcome = await actor.runStallWatchdogProbeForTesting(
            socket: live.socket,
            generation: live.generation,
            voicedBuffersSinceInbound: 30,
            secondsSinceLastInbound: 25,
            secondsSinceLastVoicedAudio: 0
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed, 1.0,
            "Probe must observe the timeout when sendPing() never resolves (took \(elapsed) s)."
        )
        XCTAssertEqual(outcome, .pingFailedAndReconnected)

        _ = await actor.stop(saveTo: nil)
    }

    /// The watchdog Task must be torn down on `stop()`. After stop,
    /// the watchdog must not keep firing pings on a recurring cadence:
    /// any one in-flight probe that was already past its identity
    /// guard may complete, but subsequent intervals must NOT issue
    /// fresh pings. With a 10 ms interval, leaving the actor stopped
    /// for 300 ms with a cancelled watchdog should net at most one
    /// additional ping (the trailing in-flight probe), not the ~30
    /// pings an uncancelled watchdog would produce.
    func testWatchdogTaskCancelledOnStop() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        await actor.setStallWatchdogIntervalForTesting(0.01)
        await actor.setStallWatchdogThresholdsForTesting(
            voicedBuffers: 0,
            secondsSinceLastInbound: 0
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        // Let the watchdog fire at least once.
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard let socket = connector.lastIssuedSocket else {
            XCTFail("Expected an issued socket.")
            return
        }
        let beforeStop = socket.pingCallCount

        _ = await actor.stop(saveTo: nil)

        // Give the (now cancelled) watchdog plenty of opportunities
        // to fire. With cancellation working, ping count must not
        // climb proportional to the elapsed interval count.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let afterStop = socket.pingCallCount
        let extraPings = afterStop - beforeStop
        XCTAssertLessThanOrEqual(
            extraPings, 1,
            "Watchdog must be cancelled on stop(); at most one in-flight ping is acceptable (before=\(beforeStop), after=\(afterStop))."
        )
    }

    // MARK: - Finding #8 — Server `error` events must escalate the lifecycle

    /// A server-issued `{"type":"error"}` event delivered through the
    /// success arm of `socket.receive()` must escalate out of `.live`
    /// — either by scheduling a reconnect or transitioning to a
    /// terminal state. The bug being pinned: the receive success arm
    /// publishes a "failed" snapshot, but never tears down the live
    /// socket; the loop spins back into `await socket.receive()` and
    /// the lifecycle stays in `.live` forever despite the server having
    /// reported a session error. We pin the escalation by observing
    /// the generation change after the reconnect lands.
    func testServerErrorEventEscalatesOutOfLive() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            configuration: .init(reconnectDelays: [0.05])
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let socket = connector.lastIssuedSocket,
              let preLive = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live socket + identity.")
            return
        }

        // Deliver a server `error` event through the receive loop's
        // success arm. The actor must transition out of `.live` and
        // reach `.reconnecting` (then back into `.live`, rotated).
        socket.enqueueScriptedMessage(.text(
            "{\"type\":\"error\",\"error\":{\"message\":\"upstream session failed\"}}"
        ))

        // Wait long enough for the reconnect to complete (delay 0.05 s
        // + claim/socket open).
        try? await Task.sleep(nanoseconds: 400_000_000)

        // The actor must have rotated to a new generation — proof
        // that it left `.live` rather than spinning back into receive.
        let lifecycle = await actor.lifecycleSnapshotForTesting()
        switch lifecycle {
        case .live(let g):
            XCTAssertNotEqual(
                g, preLive.generation,
                "Server error must rotate generation; got same identity \(lifecycle)."
            )
        case .claiming, .reconnecting:
            break // ok — still escalating
        default:
            XCTFail("Server error event must escalate out of .live. got \(lifecycle)")
        }

        _ = await actor.stop(saveTo: nil)
    }

    /// `error` event escalation must also drive a fresh claim through
    /// the connector — i.e. it goes through the normal reconnect path
    /// rather than silently staying in `.live`.
    func testServerErrorEventTriggersReconnectClaim() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            configuration: .init(reconnectDelays: [0.05])
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let socket = connector.lastIssuedSocket else {
            XCTFail("Expected a live socket.")
            return
        }
        socket.enqueueScriptedMessage(.text(
            "{\"type\":\"error\",\"error\":{\"message\":\"upstream session failed\"}}"
        ))

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThanOrEqual(
            connector.claimCallCount, 2,
            "Server error must reschedule a claim, not be silently swallowed."
        )

        _ = await actor.stop(saveTo: nil)
    }

    /// A failing `socket.send(...)` for an audio frame must NOT be
    /// silently swallowed by `try?` — a dead socket signals the
    /// session needs to escalate. Pin escalation by observing the
    /// claim count climb (proves reconnect cycle ran).
    func testSendFailureEscalatesOutOfLive() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            configuration: .init(reconnectDelays: [0.05])
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let socket = connector.lastIssuedSocket,
              let preLive = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live socket + identity.")
            return
        }
        // Make every subsequent send fail.
        socket.setSendHandler({ _ in
            throw NSError(domain: "send.failed", code: 99)
        })

        // Pump a single VOICED audio frame through (so the threshold
        // gate / commit-on-success path doesn't matter; send is
        // attempted on every frame). The send will throw; the actor
        // must escalate.
        await actor.appendPCM16ForTesting(Self.makeVoicedPCM16(byteCount: 1_600))

        // Allow the reconnect cycle to land.
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertGreaterThanOrEqual(
            connector.claimCallCount, 2,
            "send() failure must trigger a reconnect claim, not be silently swallowed."
        )

        let lifecycle = await actor.lifecycleSnapshotForTesting()
        switch lifecycle {
        case .live(let g):
            XCTAssertNotEqual(
                g, preLive.generation,
                "send() failure must rotate generation; got same identity \(lifecycle)."
            )
        case .claiming, .reconnecting:
            break
        default:
            XCTFail("send() failure must escalate out of .live; got \(lifecycle)")
        }

        _ = await actor.stop(saveTo: nil)
    }

    // MARK: - Finding #5 — Manual input_audio_buffer.commit

    /// Transcription mode must accumulate sent audio bytes and emit
    /// `input_audio_buffer.commit` events once the legacy 67,200-byte
    /// threshold is reached. Without commits, OpenAI's transcription
    /// pipeline never finalises the buffer.
    func testTranscriptionModeEmitsManualCommitOnByteThreshold() async {
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

        guard let socket = connector.lastIssuedSocket else {
            XCTFail("Expected a live socket.")
            return
        }

        // Feed ~70 KB of voiced PCM16 in 10 KB chunks. Total > 67_200
        // (the legacy `manualCommitByteThreshold`).
        for _ in 0..<7 {
            await actor.appendPCM16ForTesting(Self.makeVoicedPCM16(byteCount: 10_000))
        }
        // Give the actor's audio task a moment to drain.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let commits = socket.sentTexts.filter {
            $0.contains("\"input_audio_buffer.commit\"") ||
                $0.contains("\"type\":\"input_audio_buffer.commit\"") ||
                $0.contains("input_audio_buffer.commit")
        }
        XCTAssertGreaterThanOrEqual(
            commits.count, 1,
            "Transcription mode must emit at least one input_audio_buffer.commit after ~70 KB of voiced audio. Sent texts: \(socket.sentTexts.count) frames."
        )

        _ = await actor.stop(saveTo: nil)
    }

    /// `stop(saveTo:)` in transcription mode must force-commit any
    /// remaining buffered audio (even below the threshold) before
    /// cancelling the socket — otherwise the final utterance is lost
    /// when the user clicks stop mid-sentence.
    func testTranscriptionStopForceCommitsRemainingAudio() async {
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

        guard let socket = connector.lastIssuedSocket else {
            XCTFail("Expected a live socket.")
            return
        }

        // Feed ~5 KB — above the minimum (4_800) but well below the
        // 67_200 threshold, so the recurring commit must NOT trigger
        // automatically.
        await actor.appendPCM16ForTesting(Self.makeVoicedPCM16(byteCount: 5_000))
        try? await Task.sleep(nanoseconds: 50_000_000)

        let commitsBeforeStop = socket.sentTexts.filter {
            $0.contains("input_audio_buffer.commit")
        }.count
        XCTAssertEqual(
            commitsBeforeStop, 0,
            "Below-threshold audio must NOT auto-commit."
        )

        _ = await actor.stop(saveTo: nil)

        let commitsAfterStop = socket.sentTexts.filter {
            $0.contains("input_audio_buffer.commit")
        }.count
        XCTAssertGreaterThanOrEqual(
            commitsAfterStop, 1,
            "stop() must force-commit remaining transcription audio."
        )
    }

    /// Translation mode is a continuous stream — the upstream rejects
    /// `commit` / `clear` events. On `stop()` it sends `session.close`
    /// to teardown cleanly. Assert the inverse: no commit events
    /// regardless of byte count, and at least one `session.close` on
    /// stop.
    func testTranslationModeNeverCommitsAndSendsSessionCloseOnStop() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .translation(targetLanguage: "zh")
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let socket = connector.lastIssuedSocket else {
            XCTFail("Expected a live socket.")
            return
        }

        // Feed > 67_200 bytes — far more than the transcription
        // threshold. Translation mode must STILL never commit.
        for _ in 0..<8 {
            await actor.appendPCM16ForTesting(Self.makeVoicedPCM16(byteCount: 10_000))
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        let commits = socket.sentTexts.filter { $0.contains("input_audio_buffer.commit") }
        XCTAssertEqual(commits.count, 0, "Translation mode must NEVER send commit events.")

        _ = await actor.stop(saveTo: nil)

        let closeEvents = socket.sentTexts.filter {
            $0.contains("\"type\":\"session.close\"") || $0.contains("session.close")
        }
        XCTAssertGreaterThanOrEqual(
            closeEvents.count, 1,
            "Translation mode must send session.close on stop. Texts: \(socket.sentTexts)"
        )
    }

    /// Counter reset on socket rotation: after a reconnect, the
    /// commit-byte counter must start from zero (not carry over
    /// bytes from the previous socket). Pinned by feeding audio,
    /// rotating, feeding less than the threshold, and asserting NO
    /// commit fires on the new socket.
    func testCommitCountersResetOnReconnect() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            configuration: .init(reconnectDelays: [0.05])
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        // Push some audio into the first socket BUT below the threshold,
        // so no commit fires there.
        await actor.appendPCM16ForTesting(Self.makeVoicedPCM16(byteCount: 60_000))
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Rotate. The reconnect path resets per-socket counters.
        await actor.reconnectNow()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let freshSocket = connector.lastIssuedSocket else {
            XCTFail("Expected fresh socket.")
            return
        }

        // Push just 10 KB. If counters were NOT reset on rotation, the
        // total since the old socket would be 70 KB and trigger commit.
        // Counters being reset means this 10 KB stays below 67_200.
        await actor.appendPCM16ForTesting(Self.makeVoicedPCM16(byteCount: 10_000))
        try? await Task.sleep(nanoseconds: 100_000_000)

        let commits = freshSocket.sentTexts.filter { $0.contains("input_audio_buffer.commit") }
        XCTAssertEqual(
            commits.count, 0,
            "After rotation, the byte counter must start at 0 — 10 KB alone should not trigger a commit. Fresh sentTexts: \(freshSocket.sentTexts.count) frames."
        )

        _ = await actor.stop(saveTo: nil)
    }

    // MARK: - Finding #6 — stop() awaits close handshake

    /// `stop()` must return within a bounded window even if the
    /// socket never confirms close. Hard timeout prevents the actor
    /// from hanging in `.stopping`.
    func testStopReturnsEvenIfCloseHandshakeStalls() async {
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

        guard let socket = connector.lastIssuedSocket else {
            XCTFail("Expected a live socket.")
            return
        }
        // Disable the auto-resolve so cancel() does NOT signal
        // waitForClose() — emulates a peer that never replies to our
        // close frame.
        socket.setAutoSignalCloseOnCancel(false)
        // Use a tight stop timeout so the test stays fast.
        await actor.setStopCloseHandshakeTimeoutForTesting(0.1)

        let start = Date()
        _ = await actor.stop(saveTo: nil)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed, 1.0,
            "stop() must observe a close-handshake timeout when the peer never confirms (took \(elapsed) s)."
        )

        let lifecycle = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(lifecycle, .stopped)
    }

    /// `stop()` must actually AWAIT the close handshake when the
    /// socket delivers a close shortly after. The wall-clock for
    /// stop() must be at least the close-delivery delay (proves we
    /// awaited it instead of flipping to `.stopped` immediately).
    func testStopAwaitsCloseHandshakeWhenSocketDelivers() async {
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

        guard let socket = connector.lastIssuedSocket else {
            XCTFail("Expected a live socket.")
            return
        }
        // Disable auto-signal — we'll deliver the close manually
        // after a delay.
        socket.setAutoSignalCloseOnCancel(false)
        await actor.setStopCloseHandshakeTimeoutForTesting(5.0)

        // Deliver the close ~150 ms after stop() is invoked.
        Task.detached { [socket] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            socket.simulateCloseSignal()
        }

        let start = Date()
        _ = await actor.stop(saveTo: nil)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(
            elapsed, 0.12,
            "stop() must await close-handshake. Returned in \(elapsed) s, suggesting we flipped to .stopped without waiting."
        )
        XCTAssertLessThan(
            elapsed, 2.0,
            "stop() must return promptly once close is delivered."
        )
    }

    // MARK: - Finding #10 — previous_item_id orders the transcript

    /// Two transcript completions arrive on the same actor; the
    /// second arrives FIRST but references the first as its
    /// `previous_item_id`. The displayed timeline must end up in
    /// `[first, second]` order, not arrival order.
    func testOutOfOrderItemsRespectPreviousItemID() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        // Ingest item-2 FIRST (a complete sentence), with
        // previous_item_id pointing at item-1.
        _ = await actor.ingestReceiveEventJSONForTesting(
            "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"item_id\":\"item-2\",\"previous_item_id\":\"item-1\",\"transcript\":\"World.\"}"
        )
        // Then ingest item-1 completed.
        let final = await actor.ingestReceiveEventJSONForTesting(
            "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"item_id\":\"item-1\",\"transcript\":\"Hello.\"}"
        )

        // After both arrive, the published snapshot should reflect the
        // re-ordered timeline. The display segmenter starts a NEW
        // segment after a sentence boundary (period), so we get two
        // segments rather than one merged segment.
        guard let snapshot = final else {
            XCTFail("Expected a snapshot after item-1 arrived.")
            return
        }
        XCTAssertEqual(
            snapshot.segments.count, 2,
            "Two completed items separated by sentence boundary must produce two segments. got: \(snapshot.segments.map(\.sourceText))"
        )
        XCTAssertEqual(
            snapshot.segments[0].sourceText, "Hello.",
            "Order must follow previous_item_id, not arrival. got: \(snapshot.segments.map(\.sourceText))"
        )
        XCTAssertEqual(
            snapshot.segments[1].sourceText, "World.",
            "Order must follow previous_item_id, not arrival. got: \(snapshot.segments.map(\.sourceText))"
        )
    }

    // MARK: - Bugbot Round 2 Finding A — committed events carry the ordering signal

    /// Production OpenAI Realtime API: `previous_item_id` is carried on
    /// the `input_audio_buffer.committed` event (NOT on the subsequent
    /// transcription delta/completed events — those only carry
    /// `item_id`, `content_index`, and `delta`/`transcript`).
    ///
    /// This test models the production wire shape: three `committed`
    /// events arrive in order A→B→C establishing the timeline, then the
    /// transcription `delta`/`completed` events for those items arrive
    /// OUT OF ORDER (C first, then A, then B). The displayed timeline
    /// MUST end up as A→B→C because the commit-time ordering signal
    /// is authoritative — not the delta arrival order.
    func testCommittedEventsEstablishOrderingForOutOfOrderDeltas() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        // Phase 1 — three commits arrive in order, establishing A→B→C.
        _ = await actor.ingestReceiveEventJSONForTesting(
            "{\"type\":\"input_audio_buffer.committed\",\"item_id\":\"item-A\"}"
        )
        _ = await actor.ingestReceiveEventJSONForTesting(
            "{\"type\":\"input_audio_buffer.committed\",\"item_id\":\"item-B\",\"previous_item_id\":\"item-A\"}"
        )
        _ = await actor.ingestReceiveEventJSONForTesting(
            "{\"type\":\"input_audio_buffer.committed\",\"item_id\":\"item-C\",\"previous_item_id\":\"item-B\"}"
        )

        // Phase 2 — transcription completed events arrive OUT OF ORDER
        // (C, A, B) and carry NO previous_item_id (matching production).
        _ = await actor.ingestReceiveEventJSONForTesting(
            "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"item_id\":\"item-C\",\"transcript\":\"Charlie.\"}"
        )
        _ = await actor.ingestReceiveEventJSONForTesting(
            "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"item_id\":\"item-A\",\"transcript\":\"Alpha.\"}"
        )
        let final = await actor.ingestReceiveEventJSONForTesting(
            "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"item_id\":\"item-B\",\"transcript\":\"Bravo.\"}"
        )

        guard let snapshot = final else {
            XCTFail("Expected a snapshot after item-B completed arrived.")
            return
        }
        XCTAssertEqual(
            snapshot.segments.count, 3,
            "Three sentence-terminated items must yield three segments. got: \(snapshot.segments.map(\.sourceText))"
        )
        XCTAssertEqual(
            snapshot.segments[0].sourceText, "Alpha.",
            "Order must follow commit-time previous_item_id, not delta arrival. got: \(snapshot.segments.map(\.sourceText))"
        )
        XCTAssertEqual(
            snapshot.segments[1].sourceText, "Bravo.",
            "Order must follow commit-time previous_item_id, not delta arrival. got: \(snapshot.segments.map(\.sourceText))"
        )
        XCTAssertEqual(
            snapshot.segments[2].sourceText, "Charlie.",
            "Order must follow commit-time previous_item_id, not delta arrival. got: \(snapshot.segments.map(\.sourceText))"
        )
    }

    // MARK: - Test fixtures

    /// Make a PCM16 little-endian buffer of `byteCount` bytes whose
    /// rough RMS clears `RealtimeAudioEncoder.containsLikelySpeech`.
    /// Used by every test that wants the stall watchdog / commit-byte
    /// accounting to actually count the frame.
    static func makeVoicedPCM16(byteCount: Int) -> Data {
        // Each sample is 2 bytes; alternate 0x40, 0x10 → ~Int16(0x1040).
        // |0x1040| ≫ 240, so containsLikelySpeech() returns true.
        var data = Data(count: byteCount)
        for i in 0..<byteCount {
            data[i] = (i & 1) == 0 ? 0x40 : 0x10
        }
        return data
    }
}
