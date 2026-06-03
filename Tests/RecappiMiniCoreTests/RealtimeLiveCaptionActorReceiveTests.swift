import XCTest
@testable import RecappiMini

/// Phase 3c — receive event publishing, stall watchdog with
/// ping-before-reconnect, and terminal close codes (4000-4009).
///
/// The actor stops being a lifecycle skeleton in this phase: receive
/// events parse server messages, advance the transcript timeline, and
/// publish snapshots into an `AsyncStream<LiveCaptionSnapshot>` so the
/// legacy class can shim through it in Phase 3d.
///
/// The stall watchdog ports the legacy `evaluateStallWatchdog` /
/// `applyStallPingOutcome` mechanism inside the actor: counters live
/// in the actor isolation, the watchdog Task is owned by `.live`, and
/// cancelling it on state transitions is the natural cleanup. Pings
/// run through the same `RealtimeSocket.sendPing()` seam tests inject.
///
/// Terminal close codes follow the legacy semantics: 4000-4009 → no
/// reconnect, transition straight to `.stopped`; any other code or
/// receive failure schedules a reconnect.
final class RealtimeLiveCaptionActorReceiveTests: XCTestCase {
    // MARK: - 3c.3 Terminal close codes

    /// Server-issued close code 4001 must transition the lifecycle to
    /// `.stopped` and surface a `.failed` status snapshot. No reconnect
    /// Task may be scheduled — the application-private 4000-4009 range
    /// signals the server has terminally reassigned the session.
    func testTerminalCloseCode4001TransitionsStraightToStopped() async {
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

        // Drive a server-issued close with the terminal code 4001.
        // Receive throws; the actor must inspect `socket.closeCode`
        // and transition to `.stopped` without a retry.
        socket.simulateCloseFromServer(
            code: 4001,
            reason: Data("replaced".utf8),
            error: NSError(domain: "fake", code: -1)
        )

        // Give the actor a few tasks to drain the failure.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let snapshot = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(snapshot, .stopped, "Terminal close must short-circuit to .stopped.")

        XCTAssertEqual(
            connector.claimCallCount, 1,
            "Terminal close must not trigger any further claim attempts."
        )
    }

    /// Code 4000 ("replaced by newer realtime session") is also in the
    /// terminal range. Pinned separately because production telemetry
    /// sees this code in particular when a second device claims the
    /// same upstream session.
    func testTerminalCloseCode4000ProducesStoppedAndNoReconnect() async {
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
        socket.simulateCloseFromServer(
            code: 4000,
            reason: nil,
            error: NSError(domain: "fake", code: -1)
        )
        try? await Task.sleep(nanoseconds: 100_000_000)

        let snapshot = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(snapshot, .stopped)
        XCTAssertEqual(connector.claimCallCount, 1)
    }

    /// Code 1011 (server error / non-terminal) must schedule a
    /// reconnect. Pins the "transient codes recover" half of the close-
    /// code contract.
    func testNonTerminalCloseCode1011SchedulesReconnect() async {
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
        socket.simulateCloseFromServer(
            code: 1011,
            reason: nil,
            error: NSError(domain: "fake", code: -1)
        )

        // Wait long enough for the reconnect retry to fire.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertGreaterThanOrEqual(
            connector.claimCallCount,
            2,
            "Non-terminal close code must schedule a reconnect."
        )

        _ = await actor.stop(saveTo: nil)
    }

    // MARK: - 3c.1 Receive event publishing

    /// `session.created` from the current socket resets the transcript-
    /// stall counters and emits no transcript snapshot (it's a warmup
    /// marker, not a caption). The actor must consume the event without
    /// regressing the lifecycle.
    func testSessionCreatedConsumedSilently() async {
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

        // Subscribe to the snapshot stream BEFORE pushing the event so
        // we don't race the publisher.
        let snapshots = await actor.captionSnapshots()
        socket.enqueueScriptedMessage(.text("{\"type\":\"session.created\"}"))

        // Don't expect any caption snapshot for this event — give the
        // actor a moment, then assert the lifecycle is still .live.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let lifecycle = await actor.lifecycleSnapshotForTesting()
        switch lifecycle {
        case .live:
            break
        default:
            XCTFail("session.created must not transition the lifecycle. got \(lifecycle)")
        }
        _ = snapshots // keep the stream alive

        _ = await actor.stop(saveTo: nil)
    }

    /// Transcript deltas must accumulate and publish a snapshot whose
    /// segments include the delta text. Two deltas for the same item
    /// must accumulate into one segment rather than producing two.
    func testTranscriptionDeltaAccumulatesAndPublishesSnapshot() async {
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

        let stream = await actor.captionSnapshots()
        let recorder = SnapshotRecorder()
        let consumer = Task {
            for await snapshot in stream {
                recorder.append(snapshot)
                if recorder.snapshots.count >= 2 { break }
            }
        }

        guard let socket = connector.lastIssuedSocket else {
            XCTFail("Expected a live socket.")
            return
        }
        socket.enqueueScriptedMessage(.text(
            "{\"type\":\"conversation.item.input_audio_transcription.delta\",\"item_id\":\"i1\",\"delta\":\"Hello\"}"
        ))
        socket.enqueueScriptedMessage(.text(
            "{\"type\":\"conversation.item.input_audio_transcription.delta\",\"item_id\":\"i1\",\"delta\":\" world\"}"
        ))

        _ = await consumer.value

        let last = recorder.snapshots.last
        XCTAssertEqual(last?.segments.count, 1, "Same item_id must coalesce into one segment.")
        XCTAssertEqual(last?.segments.first?.sourceText, "Hello world")
        XCTAssertEqual(last?.segments.first?.isFinal, false)

        _ = await actor.stop(saveTo: nil)
    }

    /// A bilingual translation session emits source / target deltas on
    /// separate event types. The actor must merge them through its
    /// internal bilingual builder and publish a segment that carries
    /// both `sourceText` and `translatedText`.
    func testBilingualDeltasMergedIntoOneSegment() async {
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

        let stream = await actor.captionSnapshots()
        let recorder = SnapshotRecorder()
        let consumer = Task {
            for await snapshot in stream {
                recorder.append(snapshot)
                if recorder.snapshots.count >= 2 { break }
            }
        }

        guard let socket = connector.lastIssuedSocket else {
            XCTFail("Expected a live socket.")
            return
        }
        socket.enqueueScriptedMessage(.text(
            "{\"type\":\"session.input_transcript.delta\",\"delta\":\"hello\"}"
        ))
        socket.enqueueScriptedMessage(.text(
            "{\"type\":\"session.output_transcript.delta\",\"delta\":\"你好\"}"
        ))

        _ = await consumer.value

        let last = recorder.snapshots.last
        XCTAssertEqual(last?.segments.count, 1)
        XCTAssertEqual(last?.segments.first?.sourceText, "hello")
        XCTAssertEqual(last?.segments.first?.translatedText, "你好")

        _ = await actor.stop(saveTo: nil)
    }

    /// A receive event delivered to the actor on a stale (rotated-out)
    /// socket must not mutate the fresh socket's transcript timeline.
    /// This is the actor-level expression of Codex Finding #3 — the
    /// identity guard at the receive entry point is the structural
    /// fix.
    func testStaleSessionCreatedDoesNotResetFreshCounters() async {
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

        // Stale session.created must not transition the lifecycle and
        // must not advance the receive identity guard's counters.
        let before = await actor.lifecycleSnapshotForTesting()
        let after = await actor.simulateReceiveOutcomeForTesting(
            socket: stale.socket,
            generation: stale.generation,
            outcome: .success(.text("{\"type\":\"session.created\"}"))
        )
        XCTAssertEqual(
            before,
            after,
            "Stale session.created must not advance the lifecycle."
        )

        _ = await actor.stop(saveTo: nil)
    }

    // MARK: - 3c.2 Stall watchdog

    /// When the watchdog detects a stall and the ping succeeds, the
    /// stall counters reset and no reconnect fires. Pins the "low-
    /// speech window is not a stall" recovery path.
    func testStallPingSuccessResetsCountersAndKeepsLive() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            configuration: .init(reconnectDelays: [10])
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let live = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live identity.")
            return
        }
        guard let mockSocket = live.socket as? MockRealtimeSocket else {
            XCTFail("Expected MockRealtimeSocket.")
            return
        }

        // Drive the actor's stall watchdog with controlled environment
        // (voiced buffers + seconds since inbound) and a scripted ping
        // result (success).
        mockSocket.setPingHandler({ /* success */ })

        let outcome = await actor.runStallWatchdogProbeForTesting(
            socket: live.socket,
            generation: live.generation,
            voicedBuffersSinceInbound: 30,
            secondsSinceLastInbound: 25,
            secondsSinceLastVoicedAudio: 0
        )
        XCTAssertEqual(outcome, .pingedAndRecovered)
        XCTAssertEqual(mockSocket.pingCallCount, 1, "Ping must fire once.")

        let snapshot = await actor.lifecycleSnapshotForTesting()
        switch snapshot {
        case .live:
            break
        default:
            XCTFail("Ping success must keep us in .live, got \(snapshot)")
        }

        _ = await actor.stop(saveTo: nil)
    }

    /// When the ping fails, the watchdog triggers a reconnect — i.e. a
    /// new claim is initiated. Pins the failure half of the watchdog
    /// contract.
    func testStallPingFailureTriggersReconnect() async {
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

        guard let live = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live identity.")
            return
        }
        guard let mockSocket = live.socket as? MockRealtimeSocket else {
            XCTFail("Expected MockRealtimeSocket.")
            return
        }
        mockSocket.setPingHandler({
            throw NSError(domain: "ping", code: 1)
        })

        let outcome = await actor.runStallWatchdogProbeForTesting(
            socket: live.socket,
            generation: live.generation,
            voicedBuffersSinceInbound: 30,
            secondsSinceLastInbound: 25,
            secondsSinceLastVoicedAudio: 0
        )
        XCTAssertEqual(outcome, .pingFailedAndReconnected)

        // Give the reconnect retry time to fire.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThanOrEqual(
            connector.claimCallCount,
            2,
            "Ping failure must trigger a new claim."
        )

        _ = await actor.stop(saveTo: nil)
    }

    /// Below the voiced-buffers / quiet-time thresholds, the watchdog
    /// must skip the ping entirely. Pins the "watchdog stays quiet
    /// during normal conversation" half of the threshold contract.
    func testStallProbeBelowThresholdsSkipsPing() async {
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

        guard let live = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live identity.")
            return
        }
        guard let mockSocket = live.socket as? MockRealtimeSocket else {
            XCTFail("Expected MockRealtimeSocket.")
            return
        }
        mockSocket.setPingHandler({ /* success */ })

        let outcome = await actor.runStallWatchdogProbeForTesting(
            socket: live.socket,
            generation: live.generation,
            voicedBuffersSinceInbound: 1,
            secondsSinceLastInbound: 1,
            secondsSinceLastVoicedAudio: 0
        )
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(mockSocket.pingCallCount, 0)

        _ = await actor.stop(saveTo: nil)
    }

    /// A stall verdict against a stale socket (one that's already been
    /// rotated out of `.live`) must NOT reset counters or reconnect the
    /// fresh socket. Mirrors the legacy class's identity guard inside
    /// `applyStallPingOutcome`.
    func testStaleStallVerdictAgainstRotatedSocketIsIgnored() async {
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
            XCTFail("Expected a live identity before rotation.")
            return
        }

        // Rotate.
        await actor.reconnectNow()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let fresh = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live identity after rotation.")
            return
        }

        // Probe with the STALE identity — even a "success" verdict
        // here must not reset the fresh socket's counters.
        let outcome = await actor.runStallWatchdogProbeForTesting(
            socket: stale.socket,
            generation: stale.generation,
            voicedBuffersSinceInbound: 30,
            secondsSinceLastInbound: 25,
            secondsSinceLastVoicedAudio: 0
        )
        // The probe is allowed to run (it doesn't know it's stale
        // yet — the legacy class's invariant is that the *outcome*
        // application is guarded). The outcome should be one of the
        // two valid resolutions; what matters is the lifecycle stays
        // on the fresh identity.
        _ = outcome

        let snapshot = await actor.lifecycleSnapshotForTesting()
        switch snapshot {
        case .live(let g) where g == fresh.generation:
            break
        default:
            XCTFail("Stale stall verdict must not transition fresh lifecycle. got \(snapshot)")
        }

        _ = await actor.stop(saveTo: nil)
    }

    // MARK: - 3c.4 Source-transcript stall (translation mode)

    /// In translation mode a single upstream socket carries BOTH the
    /// source transcript (`session.input_transcript.delta`) and the
    /// translation (`session.output_transcript.delta`). When the
    /// upstream silently stops emitting the source transcript while the
    /// translation keeps flowing, the general inbound clock stays fresh
    /// (translation deltas reset it), so the ping-based watchdog never
    /// fires. A ping would succeed anyway — the socket is alive — and
    /// never recover the dead source stream. The watchdog must instead
    /// detect the source-specific stall and rotate to a fresh upstream
    /// session, surfacing a visible reconnecting indicator.
    func testSourceTranscriptStallReconnectsInTranslationMode() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .translation(targetLanguage: "es"),
            configuration: .init(reconnectDelays: [0.05])
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
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let live = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live identity.")
            return
        }
        guard let mockSocket = live.socket as? MockRealtimeSocket else {
            XCTFail("Expected MockRealtimeSocket.")
            return
        }
        // A ping here WOULD succeed (the socket is alive, carrying
        // translation) — prove the watchdog reconnects without relying
        // on a ping failure.
        mockSocket.setPingHandler({ /* success */ })

        // General inbound is FRESH (translation deltas keep resetting
        // it) but the SOURCE transcript has been silent past threshold
        // while audio is voiced.
        let outcome = await actor.runStallWatchdogProbeForTesting(
            socket: live.socket,
            generation: live.generation,
            voicedBuffersSinceInbound: 0,
            secondsSinceLastInbound: 0,
            secondsSinceLastVoicedAudio: 0,
            voicedBuffersSinceSourceInbound: 30,
            secondsSinceLastSourceInbound: 25
        )
        XCTAssertEqual(outcome, .sourceStalledAndReconnected)
        XCTAssertEqual(mockSocket.pingCallCount, 0, "Source stall must reconnect directly, not ping.")

        // The reconnect must re-claim a fresh upstream session.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThanOrEqual(
            connector.claimCallCount,
            2,
            "Source stall must trigger a new claim."
        )

        // The freeze + recovery must be visible: a `.reconnecting`
        // snapshot carrying the transcription-specific message.
        let reconnecting = recorder.snapshots.first {
            $0.phase == .reconnecting && $0.message == "Reconnecting transcription…"
        }
        XCTAssertNotNil(
            reconnecting,
            "Source stall must publish a transcription-specific reconnecting snapshot."
        )

        consumer.cancel()
        _ = await actor.stop(saveTo: nil)
    }

    /// In translation mode, when the source transcript is still fresh
    /// (below threshold) the watchdog must stay quiet — a healthy
    /// bilingual session must never be torn down.
    func testFreshSourceTranscriptDoesNotReconnectInTranslationMode() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .translation(targetLanguage: "es")
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let live = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live identity.")
            return
        }

        let outcome = await actor.runStallWatchdogProbeForTesting(
            socket: live.socket,
            generation: live.generation,
            voicedBuffersSinceInbound: 0,
            secondsSinceLastInbound: 0,
            secondsSinceLastVoicedAudio: 0,
            voicedBuffersSinceSourceInbound: 1,
            secondsSinceLastSourceInbound: 1
        )
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(connector.claimCallCount, 1, "A fresh source must not reconnect.")

        _ = await actor.stop(saveTo: nil)
    }

    /// Transcription mode has no translation stream masking a stall, so
    /// the source-stall branch must NOT apply — a stale transcript there
    /// keeps the existing ping-first contract. With both clocks past
    /// threshold and a successful ping, the verdict stays
    /// `.pingedAndRecovered`, never `.sourceStalledAndReconnected`.
    func testSourceStallBranchDoesNotApplyInTranscriptionMode() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            configuration: .init(reconnectDelays: [10])
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let live = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live identity.")
            return
        }
        guard let mockSocket = live.socket as? MockRealtimeSocket else {
            XCTFail("Expected MockRealtimeSocket.")
            return
        }
        mockSocket.setPingHandler({ /* success */ })

        let outcome = await actor.runStallWatchdogProbeForTesting(
            socket: live.socket,
            generation: live.generation,
            voicedBuffersSinceInbound: 30,
            secondsSinceLastInbound: 25,
            secondsSinceLastVoicedAudio: 0,
            voicedBuffersSinceSourceInbound: 30,
            secondsSinceLastSourceInbound: 25
        )
        XCTAssertEqual(outcome, .pingedAndRecovered)
        XCTAssertEqual(mockSocket.pingCallCount, 1, "Transcription mode must still ping first.")

        _ = await actor.stop(saveTo: nil)
    }

    /// The source-stall reconnect rotates a socket that is still alive
    /// (carrying translation). Unlike the ping-failure path, the old
    /// socket is NOT already dead, so it must be explicitly torn down —
    /// otherwise the upstream session leaks and two sockets can be live
    /// at once. Mirrors the teardown done by `reconnectNow` / proactive
    /// age rotation.
    func testSourceStallReconnectCancelsOldSocket() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .translation(targetLanguage: "es"),
            configuration: .init(reconnectDelays: [0.05])
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let live = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live identity.")
            return
        }
        guard let oldSocket = live.socket as? MockRealtimeSocket else {
            XCTFail("Expected MockRealtimeSocket.")
            return
        }

        _ = await actor.runStallWatchdogProbeForTesting(
            socket: live.socket,
            generation: live.generation,
            voicedBuffersSinceInbound: 0,
            secondsSinceLastInbound: 0,
            secondsSinceLastVoicedAudio: 0,
            voicedBuffersSinceSourceInbound: 30,
            secondsSinceLastSourceInbound: 25
        )

        XCTAssertTrue(oldSocket.cancelled, "Old (still-live) socket must be closed on source-stall reconnect.")
        XCTAssertEqual(oldSocket.cancelCode, 1001)

        _ = await actor.stop(saveTo: nil)
    }

    /// A FULL translation stall — both the source AND the translation
    /// streams have gone quiet — must NOT be treated as a source-only
    /// stall. The source-stall branch is for the divergent case
    /// (translation flowing, source dead); a full stall must keep the
    /// ping-first contract so a transient output delay recovers via a
    /// successful ping instead of an avoidable reconnect.
    func testFullStallInTranslationModeTakesPingFirstPath() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .translation(targetLanguage: "es"),
            configuration: .init(reconnectDelays: [10])
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let live = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live identity.")
            return
        }
        guard let mockSocket = live.socket as? MockRealtimeSocket else {
            XCTFail("Expected MockRealtimeSocket.")
            return
        }
        mockSocket.setPingHandler({ /* success */ })

        // Both clocks are stale: translation is NOT flowing either.
        let outcome = await actor.runStallWatchdogProbeForTesting(
            socket: live.socket,
            generation: live.generation,
            voicedBuffersSinceInbound: 30,
            secondsSinceLastInbound: 25,
            secondsSinceLastVoicedAudio: 0,
            voicedBuffersSinceSourceInbound: 30,
            secondsSinceLastSourceInbound: 25
        )
        XCTAssertEqual(outcome, .pingedAndRecovered)
        XCTAssertEqual(mockSocket.pingCallCount, 1, "Full stall must still ping first.")

        _ = await actor.stop(saveTo: nil)
    }

    /// Regression for "Ping masks full stall recovery": after a FULL
    /// translation stall (both source AND translation quiet) where the
    /// watchdog ping SUCCEEDS — a deliberate "defer reconnect, the socket
    /// is healthy" decision — the NEXT watchdog tick must NOT immediately
    /// rotate via the source-stall gate.
    ///
    /// The ping-success branch resets the general inbound clock. If it
    /// leaves the source-transcript clock stale, the next tick computes
    /// `secondsSinceLastInbound < threshold` (fresh purely because of the
    /// ping) while the source clock is still past threshold — so the
    /// source-stall gate fires and rotates right after the ping that was
    /// meant to defer the reconnect.
    ///
    /// This drives the REAL cross-tick clock computation through
    /// `runStallWatchdogTickForTesting` (the explicit-params probe seam
    /// bypasses it), so the post-ping source-clock freshness is what's
    /// under test.
    func testFullStallPingSuccessDoesNotSourceStallRotateOnNextTick() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .translation(targetLanguage: "es"),
            configuration: .init(reconnectDelays: [10])
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        guard let live = await actor.currentLiveIdentityForTesting() else {
            XCTFail("Expected a live identity.")
            return
        }
        guard let mockSocket = live.socket as? MockRealtimeSocket else {
            XCTFail("Expected MockRealtimeSocket.")
            return
        }
        mockSocket.setPingHandler({ /* success */ })

        // A small but nonzero quiet threshold so a freshly-reset clock
        // reads "fresh" (microseconds old) while an un-reset clock reads
        // "stale" (>= threshold). Voiced threshold 1 so a single voiced
        // frame trips the "we've been talking" gate.
        await actor.setStallWatchdogThresholdsForTesting(
            voicedBuffers: 1,
            secondsSinceLastInbound: 0.05
        )

        // Seed both clocks fresh: a source-transcript delta stamps both
        // the general and the source inbound clocks (markTranscriptOutput
        // source: true). Then voiced audio lifts both voiced counters.
        _ = await actor.ingestReceiveEventJSONForTesting(
            "{\"type\":\"session.input_transcript.delta\",\"delta\":\"hola\"}"
        )
        await actor.appendPCM16ForTesting(Self.makeVoicedPCM16(byteCount: 1_600))

        // Let both clocks age past the 50 ms threshold → FULL stall
        // (neither stream has produced inbound since the seed).
        try? await Task.sleep(nanoseconds: 80_000_000)

        // Tick 1: full stall → ping-first path; the ping succeeds, which
        // resets the general clock (and, with the fix, the source clock).
        let firstOutcome = await actor.runStallWatchdogTickForTesting(
            socket: live.socket,
            generation: live.generation
        )
        XCTAssertEqual(
            firstOutcome,
            .pingedAndRecovered,
            "Full stall must take the ping-first path and recover on a successful ping."
        )
        XCTAssertEqual(mockSocket.pingCallCount, 1, "Full stall must ping exactly once.")

        // Tick 2 immediately (no further sleep): the general clock is
        // fresh from the ping, the source clock should ALSO have been
        // refreshed by the ping-success. Without the fix the source clock
        // is still stale, so the source-stall gate fires and rotates.
        let secondOutcome = await actor.runStallWatchdogTickForTesting(
            socket: live.socket,
            generation: live.generation
        )
        XCTAssertNotEqual(
            secondOutcome,
            .sourceStalledAndReconnected,
            "A successful full-stall ping must defer the reconnect — the next tick must not source-stall rotate."
        )
        XCTAssertEqual(
            connector.claimCallCount,
            1,
            "Ping-deferred recovery must not have re-claimed a fresh upstream session."
        )

        _ = await actor.stop(saveTo: nil)
    }

    /// Make a PCM16 little-endian buffer whose rough RMS clears
    /// `RealtimeAudioEncoder.containsLikelySpeech`, so the watchdog's
    /// voiced-buffer counters actually count the frame.
    private static func makeVoicedPCM16(byteCount: Int) -> Data {
        var data = Data(count: byteCount)
        for i in 0..<byteCount {
            data[i] = (i & 1) == 0 ? 0x40 : 0x10
        }
        return data
    }
}

// MARK: - Snapshot recorder

/// Captures snapshots delivered through the actor's `captionSnapshots()`
/// AsyncStream so tests can assert on the published payloads.
final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [LiveCaptionSnapshot] = []

    var snapshots: [LiveCaptionSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return _snapshots
    }

    func append(_ snapshot: LiveCaptionSnapshot) {
        lock.lock()
        _snapshots.append(snapshot)
        lock.unlock()
    }
}
