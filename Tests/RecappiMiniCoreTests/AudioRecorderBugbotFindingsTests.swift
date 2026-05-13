import XCTest
@testable import RecappiMini

/// Pinning tests for the three Cursor Bugbot inline-review findings on
/// PR #9 (`refactor/realtime-actor-lifecycle`).
///
///   A — `blockingActorDrain` was bridging from MainActor into actor
///       isolation through `DispatchSemaphore.wait()`. We replaced the
///       bridge with a nonisolated lock-guarded mirror
///       (`drainEntriesNonblocking()`) so MainActor never blocks the
///       cooperative thread pool when draining the outgoing actor's
///       entries during a restart.
///   B — The actor refactor dropped the `contextHint` parameter on
///       `provider.start`. The legacy
///       `BackendRealtimeLiveCaptionTranscriber` sent the hint as a
///       `conversation.item.create` system message on `session.created`;
///       the new actor now does the same.
///   C — `AudioRecorder.reset()` cleared `liveCaptionState` and cancelled
///       `liveCaptionSnapshotTask` but never touched `pendingRestartTask`.
///       A subsequent recording's first `restartLiveCaptions` would
///       chain off the stale task and delay the new restart.
///
/// Each test pins ONE bug. Pre-existing behaviour (the carryover store,
/// the restart-generation guard, the close-handshake await) is
/// regression-tested elsewhere.
final class AudioRecorderBugbotFindingsTests: XCTestCase {

    // MARK: - Finding A — nonisolated drain mirror

    /// `drainEntriesNonblocking()` returns the same entries the
    /// on-actor `drainEntries()` would return, WITHOUT entering actor
    /// isolation. We seed the actor's transcript via the
    /// `appendEntriesForTesting` seam (which routes through the same
    /// timeline the receive loop fills + calls `updateDrainMirror`),
    /// then verify a fully synchronous read returns the same entries
    /// `drainEntries()` would on `stop()`.
    func testDrainEntriesNonblockingMirrorsOnActorDrain() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        let seed: [LiveCaptionEntry] = [
            LiveCaptionEntry(text: "alpha", isFinal: true, startedAtMs: nil, endedAtMs: nil),
            LiveCaptionEntry(text: "beta", isFinal: true, startedAtMs: nil, endedAtMs: nil),
        ]
        await actor.appendEntriesForTesting(seed)

        // The synchronous nonisolated read must return the same
        // entries an on-actor `drainEntries()` would, with no
        // blocking, no semaphore, no Task hop.
        let mirrored = actor.drainEntriesNonblocking()
        XCTAssertEqual(mirrored, seed, "Mirror must match the on-actor drain shape.")

        // And the on-actor drain itself must still return the same
        // entries — the mirror is an adjunct, not a replacement.
        let onActor = await actor.drainEntriesForTesting()
        XCTAssertEqual(onActor, seed, "On-actor drainEntries must match the seeded timeline.")
    }

    /// Before any transcript activity, the mirror is empty — matching
    /// the legacy "no entries captured yet" baseline.
    func testDrainEntriesNonblockingIsEmptyOnFreshActor() {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        XCTAssertEqual(actor.drainEntriesNonblocking(), [])
    }

    // MARK: - Finding B — contextHint reaches the OpenAI socket

    /// Constructing the actor with a `contextHint` and driving a
    /// `session.created` event through the receive loop must result in
    /// EXACTLY one `conversation.item.create` system-message frame on
    /// the socket, with the hint text in `content[0].text`.
    func testTranscriptionModeSendsContextHintAfterSessionCreated() async throws {
        let connector = MockRealtimeSessionConnector()
        let hint = "Meeting: weekly engineering sync. Focus on transcripts."
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            contextHint: hint
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

        socket.enqueueScriptedMessage(.text("{\"type\":\"session.created\"}"))
        // Give the receive loop a moment to consume the event and
        // dispatch the context-hint send.
        try? await Task.sleep(nanoseconds: 80_000_000)

        let contextHintEvents = socket.sentTexts.compactMap(Self.decodeContextHintIfPresent)
        XCTAssertEqual(
            contextHintEvents.count, 1,
            "Transcription mode must send exactly one conversation.item.create. Sent texts: \(socket.sentTexts)"
        )
        XCTAssertEqual(
            contextHintEvents.first, hint,
            "The hint payload must match the value handed to the actor's init."
        )

        _ = await actor.stop(saveTo: nil)
    }

    /// Translation mode rejects `conversation.item.create`, so the
    /// actor's constructor strips the hint and no system-message
    /// frame is sent — even after a `session.created` arrives.
    func testTranslationModeDoesNotSendContextHint() async throws {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .translation(targetLanguage: "es"),
            contextHint: "ignored in translation mode"
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

        socket.enqueueScriptedMessage(.text("{\"type\":\"session.created\"}"))
        try? await Task.sleep(nanoseconds: 80_000_000)

        let contextHintEvents = socket.sentTexts.compactMap(Self.decodeContextHintIfPresent)
        XCTAssertTrue(
            contextHintEvents.isEmpty,
            "Translation mode must never emit conversation.item.create. Sent: \(socket.sentTexts)"
        )

        _ = await actor.stop(saveTo: nil)
    }

    /// Empty / whitespace-only hints collapse to nil at init, so no
    /// `conversation.item.create` is sent even in transcription mode.
    /// Pins the "trimmed empty → nil" branch.
    func testEmptyContextHintIsNotSent() async throws {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            contextHint: "   \n   "
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

        socket.enqueueScriptedMessage(.text("{\"type\":\"session.created\"}"))
        try? await Task.sleep(nanoseconds: 80_000_000)

        let contextHintEvents = socket.sentTexts.compactMap(Self.decodeContextHintIfPresent)
        XCTAssertTrue(
            contextHintEvents.isEmpty,
            "Whitespace-only hints must be treated as nil. Sent: \(socket.sentTexts)"
        )

        _ = await actor.stop(saveTo: nil)
    }

    /// The hint is delivered at most once per live socket — receiving
    /// a second `session.created` on the SAME socket must not produce
    /// a duplicate send.
    func testContextHintSentAtMostOncePerSocket() async throws {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            contextHint: "one-shot"
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

        socket.enqueueScriptedMessage(.text("{\"type\":\"session.created\"}"))
        try? await Task.sleep(nanoseconds: 80_000_000)
        socket.enqueueScriptedMessage(.text("{\"type\":\"transcription_session.created\"}"))
        try? await Task.sleep(nanoseconds: 80_000_000)

        let contextHintEvents = socket.sentTexts.compactMap(Self.decodeContextHintIfPresent)
        XCTAssertEqual(
            contextHintEvents.count, 1,
            "The per-socket `didSendContextHint` guard must dedupe. Sent: \(socket.sentTexts)"
        )

        _ = await actor.stop(saveTo: nil)
    }

    // MARK: - Finding C — reset() cancels the pending restart chain

    /// `AudioRecorder.reset()` must cancel an in-flight
    /// `pendingRestartTask` so an orphaned task from the previous
    /// recording cannot chain into the next recording's first
    /// `restartLiveCaptions` via `await previousRestartTask?.value`.
    ///
    /// We install a long-suspended Task via the
    /// `setPendingRestartTaskForTesting(_:)` seam, then call `reset()`
    /// and assert the task observed cancellation AND the field was
    /// nil-out so the chain is truly broken.
    @MainActor
    func testResetCancelsAndClearsPendingRestartTask() async {
        let recorder = AudioRecorder()

        // Long-suspended Task that mirrors a real restart Task wedged
        // in `await stopLiveCaptionsAwaitingClose(...)`. The Task
        // records whether it observed cancellation so the assertion
        // distinguishes "cancelled" from "ran to completion."
        let observedCancellation = ObservationFlag()
        let parked = Task<Void, Never> {
            // 5 seconds is comfortably longer than any reasonable test
            // delay; if `reset()` does not cancel, the Task is still
            // suspended when we check.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled {
                await observedCancellation.set()
            }
        }
        recorder.setPendingRestartTaskForTesting(parked)
        XCTAssertNotNil(
            recorder.pendingRestartTaskForTesting,
            "Pre-condition: seam must install the Task."
        )

        recorder.reset()

        // After reset, the field must be nil so the next recording's
        // first `restartLiveCaptions` does not chain off this Task via
        // `await previousRestartTask?.value`.
        XCTAssertNil(
            recorder.pendingRestartTaskForTesting,
            "reset() must clear pendingRestartTask so the next restart does not await it."
        )

        // Give the parked Task time to observe its own cancellation
        // and set the flag. The cancellation arrives synchronously
        // via `Task.cancel()` but the sleep wake-up + `Task.isCancelled`
        // check are scheduled on the cooperative thread pool.
        for _ in 0..<10 {
            if await observedCancellation.value {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let wasCancelled = await observedCancellation.value
        XCTAssertTrue(
            wasCancelled,
            "reset() must call .cancel() on the in-flight restart Task."
        )
    }

    // MARK: - Helpers

    /// Decode a sent text frame as `conversation.item.create` and
    /// return the `content[0].text` value if it is one; otherwise nil.
    /// Used by the Finding B tests to scan `socket.sentTexts` for the
    /// hint frame without matching on raw JSON substrings (which
    /// would be brittle if the encoder changes key ordering).
    private static func decodeContextHintIfPresent(_ text: String) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard json["type"] as? String == "conversation.item.create" else { return nil }
        guard let item = json["item"] as? [String: Any],
              item["type"] as? String == "message",
              item["role"] as? String == "system",
              let content = item["content"] as? [[String: Any]],
              let first = content.first,
              first["type"] as? String == "input_text",
              let hintText = first["text"] as? String else {
            return nil
        }
        return hintText
    }
}

/// Tiny actor-isolated boolean flag used by the Finding C test to
/// observe whether the parked Task ran its `Task.isCancelled` check
/// after `reset()`. Plain `var` would need `@unchecked Sendable`
/// gymnastics; this is the simplest cross-actor flag.
private actor ObservationFlag {
    private var _value = false
    var value: Bool { _value }
    func set() { _value = true }
}
