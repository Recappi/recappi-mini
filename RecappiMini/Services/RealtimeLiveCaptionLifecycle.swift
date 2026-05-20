import AVFoundation
import CoreMedia
import Foundation

/// Actor-based realtime live-caption transcriber. Owns the lifecycle
/// state machine and (via the `RealtimeSessionConnector` abstraction)
/// the I/O to the OpenAI Realtime proxy. After Phase 3d this is the
/// only cloud live-caption code path; `AudioRecorder` wires sample
/// buffers in through `append(sampleBuffer:)` and subscribes to
/// snapshots via `captionSnapshots()`.
///
/// Key design points:
/// - Lifecycle is an explicit enum. After every `await` inside the
///   actor, we re-pattern-match on the current case and bail if it has
///   advanced (Swift actors are reentrant).
/// - I/O (HTTP claim + WebSocket) is abstracted behind
///   `RealtimeSessionConnector` so unit tests can drive the lifecycle
///   without standing up a real socket.
/// - `stop(saveTo:)` returns the accumulated `[LiveCaptionEntry]`
///   rather than writing them to disk. Persistence is lifted to
///   `AudioRecorder` in Phase 2 so the restart path can drain both
///   the outgoing and incoming transcribers' entries without losing
///   caption history.

// MARK: - Public types

/// Session mode passed across the connector boundary. Decides which
/// OpenAI session shape we mint (transcription vs translation) and
/// which event-type prefix the audio frames use.
enum RealtimeLiveCaptionMode: Equatable, Sendable {
    case transcription
    case translation(targetLanguage: String)

    var isTranslation: Bool {
        if case .translation = self { return true }
        return false
    }
}

/// Lifecycle case observable from tests. Mirrors the actor's private
/// `Lifecycle` enum but without the associated I/O handles, so it can
/// be `Equatable` and crossed across the actor boundary cheaply.
enum RealtimeLifecycleSnapshot: Equatable, Sendable {
    case created
    case claiming(generation: Int)
    case live(generation: Int)
    case reconnecting(generation: Int, attempt: Int)
    case stopping
    case stopped
}

// MARK: - I/O abstraction (production + test fakes share this)

/// Result of a successful `/sessions` claim, mode-agnostic.
struct RealtimeSessionClaim: Equatable, Sendable {
    let sessionId: String
    let websocketURL: URL
    let token: String
    let tokenType: String
}

/// One inbound message from the realtime socket.
enum RealtimeSocketMessage: Equatable, Sendable {
    case text(String)
    case data(Data)
}

/// Abstract WebSocket connection. The production impl wraps
/// `URLSessionWebSocketTask`; tests substitute a fake that records
/// sent frames and replays scripted receive results.
///
/// `sendPing()` is the actor's stall-watchdog probe. `closeCode` /
/// `closeReason` surface the close handshake metadata the receive loop
/// needs to distinguish terminal close codes (4000-4009 — server
/// reassigned the session) from transient ones (1011, network drops).
/// Adapters return zero / nil before a close has been observed.
protocol RealtimeSocket: AnyObject, Sendable {
    func send(text: String) async throws
    func sendPing() async throws
    func receive() async throws -> RealtimeSocketMessage
    func cancel(code: Int, reason: Data?)
    /// Suspend until the underlying transport observes a close (peer
    /// reply to our `cancel(code:reason:)`, or an asynchronous close
    /// from the server). Resolves immediately if the close has already
    /// been observed. Production adapters wire this through
    /// `URLSessionWebSocketDelegate`'s `didCloseWith` callback so
    /// `stop()` can deterministically await the close handshake before
    /// the actor flips to `.stopped`. See Codex Finding #6.
    func waitForClose() async
    var closeCode: Int { get }
    var closeReason: Data? { get }
}

/// Wraps the bits of `RecappiAPIClient` + `URLSession` the actor
/// actually needs. Lets tests inject a deterministic claim/socket
/// without instantiating a real network stack.
protocol RealtimeSessionConnector: Sendable {
    func claimSession(
        mode: RealtimeLiveCaptionMode,
        language: String
    ) async throws -> RealtimeSessionClaim

    func openSocket(for claim: RealtimeSessionClaim) async throws -> RealtimeSocket
}

// MARK: - The actor

/// New actor-based realtime live-caption transcriber. The production
/// path will adopt this in Phase 3; for now it lives next to the
/// legacy class and is only exercised by `RealtimeLiveCaptionLifecycleTests`.
actor RealtimeLiveCaptionActor {
    // MARK: Lifecycle

    /// Internal state machine. Associated values hold the I/O handles
    /// that belong to each case — when the case advances, those
    /// handles are dropped (sockets cancelled, tasks cancelled).
    private enum Lifecycle {
        case created
        case claiming(generation: Int, claimTask: Task<Void, Never>)
        case live(
            socket: RealtimeSocket,
            generation: Int,
            receiveTask: Task<Void, Never>,
            watchdogTask: Task<Void, Never>
        )
        case reconnecting(generation: Int, attempt: Int, scheduledAt: Date, delay: TimeInterval)
        case stopping(socket: RealtimeSocket?)
        case stopped

        var snapshot: RealtimeLifecycleSnapshot {
            switch self {
            case .created:
                return .created
            case .claiming(let g, _):
                return .claiming(generation: g)
            case .live(_, let g, _, _):
                return .live(generation: g)
            case .reconnecting(let g, let attempt, _, _):
                return .reconnecting(generation: g, attempt: attempt)
            case .stopping:
                return .stopping
            case .stopped:
                return .stopped
            }
        }
    }

    private var lifecycle: Lifecycle = .created
    private var nextGeneration: Int = 0

    // MARK: Diagnostic trace state (Task C)
    //
    // `lastClaimedSessionId` is captured from `RealtimeSessionClaim`
    // inside `performClaim` so every subsequent `trace(...)` line can
    // include the server-issued realtime session id. The server-side
    // proxy emits the same `sid=` into Cloudflare Workers logs, so
    // production failures can be cross-correlated end-to-end.
    //
    // `liveOpenedAt` is stamped when the lifecycle enters `.live` and
    // cleared on reconnect / stop. The receive-loop drop traces compute
    // `sinceOpenMs` from this so we can tell at-a-glance whether a
    // drop happened just after handshake or deep into a long session.
    private var lastClaimedSessionId: String?
    private var liveOpenedAt: Date?

    // MARK: Audio routing (Phase 3b)
    //
    // Pre-live audio is buffered in a small bounded queue so frames
    // captured while the actor is still claiming or opening a socket
    // are not lost on the transition into `.live`. Overflow drops the
    // OLDEST frames first — recent speech is the more useful signal
    // when the upstream is finally ready — and increments a metric
    // counter so a test (and future production telemetry) can detect
    // sustained back-pressure. Frames submitted in `.reconnecting`,
    // `.stopping`, and `.stopped` are dropped silently; the lifecycle
    // is winding down and resurrecting it with stray audio is exactly
    // the bug-class the actor refactor exists to prevent.
    private var pendingAudio: [Data] = []
    private var droppedAudioCount: Int = 0

    // MARK: Receive state (Phase 3c)
    //
    // Transcript timeline + items map for transcription mode. Mirrors
    // the legacy class's `transcriptTimeline` / `transcriptItems` but
    // sits inside actor isolation, so we never need a serial
    // `stateQueue` to serialize mutations.
    private var transcriptTimeline: [RealtimeTranscriptKey] = []
    private var transcriptItems: [RealtimeTranscriptKey: RealtimeTranscriptItem] = [:]
    private var lastPublishedSegments: [LiveCaptionSegment] = []
    private var fallbackSequence: Int = 0
    /// Out-of-order placement table. When a delta arrives whose
    /// `previous_item_id` references an item we haven't seen yet, the
    /// new key is appended at the end of the timeline AND its desired
    /// prior is recorded here. The next time the prior key surfaces
    /// (or any timeline mutation runs), we retry the placement.
    /// Mirrors the legacy class's `pendingPreviousItemIDByKey`.
    private var pendingPreviousItemIDByKey: [RealtimeTranscriptKey: String] = [:]
    /// Translation-mode segment builder. nil for transcription mode.
    private var bilingualBuilder: RealtimeBilingualSegmentBuilder?
    /// Publishers for the caption snapshot stream(s). Each call to
    /// `captionSnapshots()` adds one continuation; the receive loop
    /// fans publishes to every active continuation.
    private var snapshotContinuations: [UUID: AsyncStream<LiveCaptionSnapshot>.Continuation] = [:]

    /// Lock-guarded mirror of the value `drainEntries()` would return,
    /// maintained alongside every transcript-state mutation. Exposed via
    /// the nonisolated `drainEntriesNonblocking()` accessor so MainActor
    /// callers can snapshot the entries without entering actor isolation
    /// (and without blocking on a `DispatchSemaphore`, which can starve
    /// the cooperative thread pool). The on-actor `drainEntries()`
    /// remains the authoritative source for `stop()` so the saved
    /// transcript shape stays byte-identical to the legacy class.
    private let drainMirrorLock = NSLock()
    nonisolated(unsafe) private var drainMirrorEntries: [LiveCaptionEntry] = []

    // MARK: Manual-commit accounting (Codex Finding #5)
    //
    // Transcription mode requires periodic `input_audio_buffer.commit`
    // events so the upstream pipeline finalises the inbound audio
    // buffer. Translation mode forbids commits (continuous stream).
    // These counters are reset on every socket rotation (claim → live)
    // so a fresh socket starts a clean commit window.
    private var hasUncommittedAudio: Bool = false
    private var uncommittedAudioByteCount: Int = 0
    private var didLogFirstAudioSend: Bool = false
    private var didLogFirstInboundEvent: Bool = false

    // MARK: Stall watchdog state (Phase 3c.2)
    //
    // Counters live on the actor, so the watchdog probe and the
    // post-ping outcome both run under actor isolation. There's no
    // DispatchQueue trip between probing and applying the verdict,
    // which removes the entire race window the legacy class's
    // `applyStallPingOutcome` had to guard against.
    private var voicedAudioBufferCountSinceInbound: Int = 0
    private var lastInboundTranscriptAt: Date?
    private var connectionStartedAt: Date?

    // MARK: Dependencies

    private let connector: RealtimeSessionConnector
    private let language: String
    private let mode: RealtimeLiveCaptionMode
    private let configuration: Configuration
    /// Optional transcription context hint sent as a
    /// `conversation.item.create` system message right after the
    /// upstream emits `session.created` / `transcription_session.created`.
    /// Mirrors the legacy `BackendRealtimeLiveCaptionTranscriber`'s
    /// `sendContextHintIfNeeded()` so recording scene templates +
    /// "extra prompt" text continue to bias transcription quality after
    /// the actor refactor. Translation mode rejects
    /// `conversation.item.create`, so the constructor strips the hint
    /// for translation sessions.
    private let contextHint: String?
    /// Per-socket guard: ensure the context hint is sent at most once
    /// per `.live` transition. Reset in `performClaim` on every fresh
    /// claim so a reconnect re-sends the hint to the new socket
    /// (matches the legacy class's `didSendContextHint = false` reset
    /// on reconnect-ready).
    private var didSendContextHint: Bool = false
    /// Set by `handleReceiveSuccess` on
    /// `session.created` / `transcription_session.created`. The receive
    /// loop reads this between receives and, if armed, awaits a
    /// `sendContextHintIfNeeded(on:)` call before looping back into
    /// `socket.receive()`. Keeping the flag isolated to the actor lets
    /// `handleReceiveSuccess` remain synchronous (the test seam
    /// `ingestReceiveEventJSONForTesting` already depends on that).
    private var pendingContextHintSend: Bool = false

    /// Tunables for retry timing + audio buffering. Carved out so tests
    /// can run with near-zero reconnect delays and a small audio cap
    /// without monkey-patching the actor or relying on `Task.sleep`
    /// long enough for the default cadence.
    struct Configuration: Sendable {
        let reconnectDelays: [TimeInterval]
        let audioBufferCapacity: Int

        init(
            reconnectDelays: [TimeInterval] = [1, 2, 5, 10, 30],
            audioBufferCapacity: Int = 128
        ) {
            self.reconnectDelays = reconnectDelays
            self.audioBufferCapacity = max(1, audioBufferCapacity)
        }

        static let `default` = Configuration()
    }

    init(
        connector: RealtimeSessionConnector,
        language: String,
        mode: RealtimeLiveCaptionMode = .transcription,
        contextHint: String? = nil,
        configuration: Configuration = .default
    ) {
        self.connector = connector
        self.language = language
        self.mode = mode
        // Translation sessions reject `conversation.item.create`; keep
        // the hint only for transcription mode. Empty / whitespace-only
        // hints collapse to nil so we don't send a no-op event.
        self.contextHint = mode.isTranslation
            ? nil
            : Self.trimmedContextHint(contextHint)
        self.configuration = configuration
        if mode.isTranslation {
            self.bilingualBuilder = RealtimeBilingualSegmentBuilder()
        }
    }

    private static func trimmedContextHint(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    // MARK: Public API

    /// Begin the session: claim → open socket → start receive loop.
    /// Idempotent if the lifecycle is already past `.created`; tests
    /// drive this directly and observe transitions via the DEBUG
    /// inspection seams below.
    func start() async {
        guard case .created = lifecycle else { return }
        trace("start", "mode=\(mode.isTranslation ? "translation" : "transcription")")
        await beginClaim(attempt: 0)
    }

    /// Stop the session. Returns the accumulated `[LiveCaptionEntry]`
    /// rather than writing them. Callers (Phase 2: `AudioRecorder`)
    /// will merge these with carryover and persist once.
    func stop(saveTo: URL?) async -> [LiveCaptionEntry] {
        trace("stop")
        // Pattern-match on the current case to capture the in-flight
        // socket (if any), cancel ongoing tasks, then transition to
        // `.stopping` while we wait for the close handshake.
        let socketToClose: RealtimeSocket?
        let shouldForceCommit: Bool
        switch lifecycle {
        case .created:
            lifecycle = .stopped
            trace("phase", "to=\(Self.snapshotTag(lifecycle.snapshot))")
            lastClaimedSessionId = nil
            liveOpenedAt = nil
            return drainEntries()
        case .claiming(_, let claimTask):
            claimTask.cancel()
            socketToClose = nil
            shouldForceCommit = false
        case .live(let socket, _, let receiveTask, let watchdogTask):
            receiveTask.cancel()
            watchdogTask.cancel()
            socketToClose = socket
            shouldForceCommit = true
        case .reconnecting:
            socketToClose = nil
            shouldForceCommit = false
        case .stopping(let socket):
            socketToClose = socket
            shouldForceCommit = false
        case .stopped:
            return drainEntries()
        }
        lifecycle = .stopping(socket: socketToClose)
        trace("phase", "to=\(Self.snapshotTag(lifecycle.snapshot))")
        // Audio captured during the shutdown window belongs to the
        // dying session. Drop it so the queue empties before we hit
        // `.stopped`. We do this BEFORE the final commit so we don't
        // race the audio task spawning a send-after-cancel.
        pendingAudio.removeAll()
        // Send the upstream-mode-appropriate teardown frame BEFORE
        // cancelling the socket so the peer sees a clean signal.
        //   - Transcription: force-commit any pending audio so the
        //     server finalises the last utterance.
        //   - Translation: explicit `session.close` event (legacy
        //     line ~130 of `BackendRealtimeLiveCaptionTranscriber`).
        // Codex Finding #5.
        if shouldForceCommit, let socket = socketToClose {
            if mode.isTranslation {
                await sendSessionCloseIfNeeded(on: socket)
            } else {
                await commitPendingAudio(on: socket, force: true)
            }
        }
        socketToClose?.cancel(code: 1001, reason: nil)
        // Await the close handshake with a hard bound. The legacy
        // class flipped straight to `.stopped` without awaiting; the
        // race against the next session's claim is what produced the
        // duplicate "proxy ... canceled" log entries that prompted
        // this investigation. Codex Finding #6.
        if let socket = socketToClose {
            await awaitCloseHandshakeWithTimeout(socket: socket)
        }
        lifecycle = .stopped
        trace("phase", "to=\(Self.snapshotTag(lifecycle.snapshot))")
        // Sensitive per-session fields are reset on terminal stop so a
        // future `start()` doesn't accidentally inherit stale state
        // (Task C: keep `lastClaimedSessionId` / `liveOpenedAt` aligned
        // with the live lifecycle window).
        lastClaimedSessionId = nil
        liveOpenedAt = nil
        finishAllSnapshotStreams()
        // Saving to disk is the AudioRecorder's job in Phase 2; we
        // simply return the entries here. The `saveTo` parameter is
        // accepted for API symmetry with the legacy class.
        _ = saveTo
        return drainEntries()
    }

    /// Wait for the socket's close handshake with a hard timeout.
    /// We use a detached pair (close-waiter + sleep-arbiter) so the
    /// timeout side can always win even if `waitForClose()` is
    /// permanently blocked. Mirrors the `racePing` arbiter pattern
    /// used by the stall watchdog.
    private func awaitCloseHandshakeWithTimeout(socket: RealtimeSocket) async {
        let bound = stopCloseHandshakeTimeout
        let arbiter = SingleShotSignal()
        let waitTask = Task.detached { @Sendable in
            await socket.waitForClose()
            arbiter.signal()
        }
        let timeoutTask = Task.detached { @Sendable in
            try? await Task.sleep(nanoseconds: UInt64(max(bound, 0) * 1_000_000_000))
            arbiter.signal()
        }
        await arbiter.wait()
        waitTask.cancel()
        timeoutTask.cancel()
    }

    /// Single-shot resume primitive used by `stop()`'s close-handshake
    /// race. Lightweight cousin of `PingRace` — we don't need to
    /// distinguish success vs failure here, just "first arm wins".
    final class SingleShotSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var signaled = false
        private var continuation: CheckedContinuation<Void, Never>?

        func signal() {
            lock.lock()
            if signaled {
                lock.unlock()
                return
            }
            signaled = true
            if let continuation = self.continuation {
                self.continuation = nil
                lock.unlock()
                continuation.resume()
            } else {
                lock.unlock()
            }
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if signaled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    /// Default upper bound on how long `stop()` waits for the WebSocket
    /// close handshake before flipping to `.stopped`. Matches the
    /// legacy class's 3-second budget so production timing is
    /// preserved. Tests trim it via `setStopCloseHandshakeTimeoutForTesting`.
    static let defaultStopCloseHandshakeTimeout: TimeInterval = 3
    private var stopCloseHandshakeTimeout: TimeInterval =
        RealtimeLiveCaptionActor.defaultStopCloseHandshakeTimeout

    /// Read-only snapshot of the transcript / bilingual state as
    /// `[LiveCaptionEntry]`. Mirrors the legacy class's
    /// `currentEntriesSnapshot()` so the on-disk shape stays
    /// byte-identical across the refactor:
    ///
    /// - Bilingual: each finalized + pending segment becomes one entry
    ///   whose `text` is the trimmed source line joined with the
    ///   translation line via `\n`.
    /// - Transcription: every non-empty timeline item becomes an entry;
    ///   when at least one final entry exists, only finals are
    ///   surfaced (so a stop mid-utterance doesn't persist a partial),
    ///   otherwise the last partial is the only entry returned.
    ///
    /// Capped at `maxSavedEntryCount` so a runaway session can't grow
    /// the on-disk transcript unbounded.
    func drainEntries() -> [LiveCaptionEntry] {
        // Bilingual: finalize any pending partial so the saved transcript
        // carries the last in-flight utterance as `isFinal: true`.
        // Transcription has no analogous side-effect — pending finality
        // is encoded directly in `RealtimeTranscriptItem.isFinal`.
        bilingualBuilder?.finalizePending()
        let entries = computeDrainEntriesSnapshot(finalizingBilingualPending: false)
        updateDrainMirrorWithEntries(entries)
        return entries
    }

    /// Pure-read snapshot used both by `drainEntries()` (after
    /// `finalizePending()` runs on-actor) and by `updateDrainMirror()`
    /// (which is called after every transcript-state mutation so the
    /// nonisolated `drainEntriesNonblocking()` accessor stays in sync).
    /// `finalizingBilingualPending` is always `false` here — the only
    /// place that finalizes is `drainEntries()`, which calls
    /// `finalizePending()` directly before invoking this helper.
    private func computeDrainEntriesSnapshot(finalizingBilingualPending: Bool) -> [LiveCaptionEntry] {
        if let builder = bilingualBuilder {
            let orderedEntries = builder.snapshot()
                .suffix(Self.maxSavedEntryCount)
                .compactMap { segment -> LiveCaptionEntry? in
                    let text = [segment.sourceText, segment.translatedText]
                        .compactMap { value -> String? in
                            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            return trimmed.isEmpty ? nil : trimmed
                        }
                        .joined(separator: "\n")
                    guard !text.isEmpty else { return nil }
                    return LiveCaptionEntry(
                        text: text,
                        isFinal: segment.isFinal,
                        startedAtMs: nil,
                        endedAtMs: nil
                    )
                }
            return Array(orderedEntries)
        }

        let orderedEntries = transcriptTimeline
            .compactMap { transcriptItems[$0] }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(Self.maxSavedEntryCount)
            .map {
                LiveCaptionEntry(
                    text: $0.text,
                    isFinal: $0.isFinal,
                    startedAtMs: nil,
                    endedAtMs: nil
                )
            }
        let finalEntries = orderedEntries.filter(\.isFinal)
        if !finalEntries.isEmpty { return finalEntries }
        return Array(orderedEntries.suffix(1))
    }

    /// Nonisolated snapshot accessor. Reads the lock-guarded mirror that
    /// `updateDrainMirror()` maintains on every transcript-state
    /// mutation. Used by `AudioRecorder.drainEntriesUsingHooks` so the
    /// MainActor carryover path (`restartLiveCaptions`,
    /// `finalizeLiveCaptionsForStop`) never blocks on a
    /// `DispatchSemaphore` to bridge into actor isolation.
    ///
    /// The mirror may lag the on-actor state by one transcript event
    /// (the receive loop publishes a snapshot before
    /// `updateDrainMirror()` runs), but that lag is on the order of
    /// microseconds and is bounded by the actor's executor; in practice
    /// it is indistinguishable from the legacy semaphore path which
    /// could observe the same race against an in-flight `appendDelta`.
    nonisolated func drainEntriesNonblocking() -> [LiveCaptionEntry] {
        drainMirrorLock.lock()
        defer { drainMirrorLock.unlock() }
        return drainMirrorEntries
    }

    /// Recompute the entries snapshot from current actor state and
    /// publish it into the nonisolated mirror under the lock. Called
    /// after every transcript-state mutation in the receive path. The
    /// snapshot uses the non-finalizing variant so we don't side-effect
    /// the bilingual builder's `pending` block between drain calls —
    /// the trailing partial appears in the mirror with its current
    /// `isFinal` value and is only promoted to `isFinal: true` by
    /// `drainEntries()` on `stop()`.
    private func updateDrainMirror() {
        updateDrainMirrorWithEntries(computeDrainEntriesSnapshot(finalizingBilingualPending: false))
    }

    private func updateDrainMirrorWithEntries(_ entries: [LiveCaptionEntry]) {
        drainMirrorLock.lock()
        drainMirrorEntries = entries
        drainMirrorLock.unlock()
    }

    /// Memory safety net (~10h of fast continuous speech). The panel
    /// renders the FULL stored timeline; the cap only prevents a
    /// runaway session from growing unbounded.
    private static let maxSavedEntryCount = 10_000

    /// Bytes of voiced audio buffered before the actor forces a
    /// manual `input_audio_buffer.commit`. Lifted byte-for-byte from
    /// the legacy class (~67 KB ≈ 1.4 s of 24 kHz PCM16 mono).
    /// Codex Finding #5.
    static let manualCommitByteThreshold = 67_200
    /// Minimum buffered bytes required to issue a commit when not
    /// forced. Below this threshold a `stop()` force-commit is still
    /// allowed but the recurring threshold-trip is not.
    static let minimumManualCommitByteCount = 4_800

    private static func modeLabel(_ mode: RealtimeLiveCaptionMode) -> String {
        switch mode {
        case .transcription:
            return "transcription"
        case .translation(let targetLanguage):
            return "translation:\(targetLanguage)"
        }
    }

    /// Force a reconnect from `.live`. No-op from other states (a
    /// caller racing against `stop()` must not be able to resurrect
    /// a torn-down session).
    func reconnectNow() async {
        guard case .live(let socket, _, let receiveTask, let watchdogTask) = lifecycle else { return }
        receiveTask.cancel()
        watchdogTask.cancel()
        socket.cancel(code: 1001, reason: nil)
        await beginClaim(attempt: 0)
    }

    /// Audio ingest. Nonisolated trampoline: decode the
    /// `CMSampleBuffer` into PCM16 little-endian bytes off-actor (the
    /// converter touches `CoreMedia` types that aren't `Sendable` and
    /// can be expensive) and then hop onto the actor to enqueue or
    /// send the encoded frame.
    nonisolated func append(sampleBuffer: CMSampleBuffer) {
        guard let payload = autoreleasepool(invoking: {
            RealtimeAudioEncoder.pcm16Data(from: sampleBuffer)
        }), !payload.isEmpty else {
            return
        }
        Task { [weak self] in
            await self?.ingestPCM16(payload)
        }
    }

    /// On-actor sink for an encoded PCM16 frame. Either sends through
    /// the live socket or enqueues into the bounded buffer; states
    /// that are winding down drop the frame outright. Tests drive this
    /// through `appendPCM16ForTesting` to bypass the `CMSampleBuffer`
    /// conversion path (exercised by the legacy class's tests today).
    private func ingestPCM16(_ payload: Data) async {
        switch lifecycle {
        case .live(let socket, _, _, _):
            await sendAudio(payload, on: socket)
        case .claiming:
            enqueuePendingAudio(payload)
        case .created, .reconnecting, .stopping, .stopped:
            // Drop. `.created` shouldn't happen in practice (start()
            // is awaited before audio capture begins) but treating it
            // as a drop matches the "audio belongs to a live or about-
            // to-be-live socket" invariant.
            break
        }
    }

    /// Append to the bounded queue, dropping the oldest frame on
    /// overflow so the queue stays at `audioBufferCapacity`. Old
    /// frames are the less useful signal once the upstream is ready
    /// to accept audio, and dropping the head matches the legacy
    /// class's "reservePendingAudioBuffer" semantics in spirit (cap +
    /// metric) while keeping the most recent speech window intact.
    private func enqueuePendingAudio(_ payload: Data) {
        if pendingAudio.count >= configuration.audioBufferCapacity {
            pendingAudio.removeFirst()
            droppedAudioCount += 1
        }
        pendingAudio.append(payload)
        // Surface sustained pre-live back-pressure into the verbose
        // trace so a stuck claim is visually obvious in the diagnostics
        // log. Threshold matches the spec's "exceeds N (say 32)" hint.
        if pendingAudio.count > 32 {
            trace("audio.send.queue_high", "queued=\(pendingAudio.count)", verboseOnly: true)
        }
    }

    /// Flush the buffered audio onto a freshly-live socket. Called
    /// from `performClaim` after the lifecycle transitions to `.live`.
    /// The send loop bails as soon as the socket identity rotates, so
    /// a concurrent `stop()` or `reconnectNow()` cannot leak frames
    /// onto a stale socket. Re-pattern-matching after each `await` is
    /// the standard actor-reentrancy guard.
    private func flushPendingAudio(socket: RealtimeSocket, generation: Int) async {
        while !pendingAudio.isEmpty {
            // Re-check identity at every iteration — the socket may
            // have rotated under us if another caller raced in.
            guard case .live(let current, let currentGeneration, _, _) = lifecycle,
                  current === socket,
                  currentGeneration == generation else {
                return
            }
            let next = pendingAudio.removeFirst()
            await sendAudio(next, on: socket)
        }
    }

    /// Send a single PCM16 frame as the OpenAI realtime
    /// `input_audio_buffer.append` event (or the `session.*`-prefixed
    /// variant for the translation endpoint). The translation endpoint
    /// rejects the un-prefixed event name and the transcription
    /// endpoint rejects the prefixed one, so getting this wrong drops
    /// audio silently — same bug the legacy class's `sendAudio` path
    /// already avoids by dispatching off `mode.isTranslation`.
    private func sendAudio(_ payload: Data, on socket: RealtimeSocket) async {
        trace("audio.send.begin", "bytes=\(payload.count)", verboseOnly: true)
        let eventType = mode.isTranslation
            ? "session.input_audio_buffer.append"
            : "input_audio_buffer.append"
        let event: [String: Any] = [
            "type": eventType,
            "audio": payload.base64EncodedString(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        // Stall-watchdog accounting: count this as a voiced buffer
        // when the rough RMS estimate trips the same threshold the
        // legacy class uses. The watchdog needs both "we are sending
        // audio" and "we haven't heard anything back" to decide a
        // probe is warranted.
        let likelySpeech = RealtimeAudioEncoder.containsLikelySpeech(payload)
        if likelySpeech {
            voicedAudioBufferCountSinceInbound += 1
        }
        do {
            try await socket.send(text: text)
        } catch {
            // A failed audio send is a strong signal the socket is
            // dead. Re-pattern-match identity before escalating so a
            // stale send error against a rotated-out socket doesn't
            // tear down the fresh one. Codex Finding #8 (b) — the
            // legacy `try?` swallowed this entirely.
            await escalateSendFailure(error: error, socket: socket)
            return
        }
        trace("audio.send.end", verboseOnly: true)
        if !didLogFirstAudioSend {
            didLogFirstAudioSend = true
            DiagnosticsLog.event(
                "live-caption",
                "audio.first_sent mode=\(Self.modeLabel(mode)) bytes=\(payload.count) likelySpeech=\(likelySpeech)"
            )
        }
        // Transcription mode: accumulate sent bytes and force a manual
        // commit once we've buffered the legacy threshold of voiced
        // audio. Translation mode is a continuous stream — the upstream
        // forbids `commit` events. Codex Finding #5.
        if !mode.isTranslation {
            hasUncommittedAudio = true
            uncommittedAudioByteCount += payload.count
            if uncommittedAudioByteCount >= Self.manualCommitByteThreshold {
                await commitPendingAudio(on: socket)
            }
        }
    }

    /// Escalate a `socket.send(...)` failure into the lifecycle's
    /// reconnect path. Mirrors the receive loop's catch arm: identity-
    /// guard, then either transition to terminal stop (if the socket
    /// already observed a 4000-4009 close) or schedule a reconnect.
    private func escalateSendFailure(error: Error, socket: RealtimeSocket) async {
        // Identity guard: the lifecycle may have rotated while the
        // send was in flight. We only escalate when we're still on the
        // SAME live socket; otherwise the rotation already handled it.
        guard case .live(let current, _, _, _) = lifecycle, current === socket else {
            return
        }
        let rawCode = socket.closeCode
        if Self.isTerminalCloseCode(rawCode) {
            await transitionToTerminalStop(rawCode: rawCode, reason: socket.closeReason)
            return
        }
        // Cancel the receive task explicitly so it doesn't race the
        // reconnect we're about to schedule. The receive loop will
        // observe cancellation, fail through, and the identity guard
        // there will short-circuit (lifecycle is no longer .live).
        if case .live(_, _, let receiveTask, let watchdogTask) = lifecycle {
            receiveTask.cancel()
            watchdogTask.cancel()
        }
        trace("ws.send_failure", "err=\(DiagnosticsLog.errorSummary(error))")
        let wrapped = RealtimeSendFailureError(underlying: error.localizedDescription)
        await scheduleReconnect(after: wrapped, attempt: 1)
    }

    /// Send the OpenAI realtime `input_audio_buffer.commit` event.
    /// Transcription mode only — the translation endpoint rejects
    /// commit / clear events. Mirrors
    /// `BackendRealtimeLiveCaptionTranscriber.commitPendingAudio`.
    private func commitPendingAudio(on socket: RealtimeSocket, force: Bool = false) async {
        guard hasUncommittedAudio else { return }
        guard force || uncommittedAudioByteCount >= Self.minimumManualCommitByteCount else {
            return
        }
        let event: [String: Any] = ["type": "input_audio_buffer.commit"]
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        do {
            try await socket.send(text: text)
            hasUncommittedAudio = false
            uncommittedAudioByteCount = 0
        } catch {
            await escalateSendFailure(error: error, socket: socket)
        }
    }

    /// Send the `session.close` event used to teardown a translation
    /// session cleanly. The translation endpoint forbids commit / clear
    /// and accepts `session.close` for an explicit close (legacy file
    /// line ~130). Failures are swallowed — we're tearing down anyway
    /// and a follow-up `socket.cancel(...)` happens in `stop()`.
    private func sendSessionCloseIfNeeded(on socket: RealtimeSocket) async {
        guard mode.isTranslation else { return }
        let event: [String: Any] = ["type": "session.close"]
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        try? await socket.send(text: text)
    }

    /// Check whether a context-hint send is currently armed AND the
    /// configuration actually has a hint to deliver. Translation mode
    /// strips the hint at init time, so the `contextHint != nil` guard
    /// covers the mode check too.
    private func shouldSendContextHint() -> Bool {
        guard pendingContextHintSend, !didSendContextHint else { return false }
        return contextHint != nil
    }

    /// Emit the legacy `BackendRealtimeLiveCaptionTranscriber`'s
    /// `conversation.item.create` system-message event so the OpenAI
    /// transcription session is biased by the recording scene template +
    /// extra prompt the user configured. Sent at most once per `.live`
    /// transition; the per-socket guard (`didSendContextHint`) is reset
    /// on every fresh claim so reconnects re-send the hint.
    ///
    /// Translation mode never reaches here — the constructor strips
    /// the hint and the translation upstream rejects
    /// `conversation.item.create` events.
    private func sendContextHintIfNeeded(on socket: RealtimeSocket) async {
        // Re-check under actor isolation in case a stop/reconnect
        // raced the receive-loop's read.
        guard shouldSendContextHint(), let hint = contextHint else {
            pendingContextHintSend = false
            return
        }
        didSendContextHint = true
        pendingContextHintSend = false
        let event: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "system",
                "content": [
                    [
                        "type": "input_text",
                        "text": hint,
                    ] as [String: Any],
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        do {
            try await socket.send(text: text)
        } catch {
            // A failed context-hint send mirrors a failed audio send:
            // the socket is likely dead, so route through the same
            // reconnect-or-terminate path. The reconnect rearms
            // `didSendContextHint = false` (via `performClaim`'s state
            // reset) so the next live socket re-attempts the hint.
            await escalateSendFailure(error: error, socket: socket)
        }
    }

    // MARK: Caption snapshot stream (Phase 3c)

    /// Public subscriber for caption snapshots. Each call hands back a
    /// fresh `AsyncStream`; the receive loop fans publishes to every
    /// active continuation, so multiple subscribers (e.g. UI + tests)
    /// can observe the same transcript without stealing events. When
    /// the lifecycle reaches `.stopped`, all continuations are
    /// finished so consumers' `for await` loops exit naturally.
    func captionSnapshots() -> AsyncStream<LiveCaptionSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            snapshotContinuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { [weak self] in
                    await self?.removeSnapshotContinuation(id: id)
                }
            }
        }
    }

    private func removeSnapshotContinuation(id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    /// Publish a snapshot to every active stream. Called from the
    /// receive loop after event handling produces a new transcript
    /// snapshot. The fan-out runs under actor isolation so multiple
    /// rapid events publish in order.
    private func publishSnapshot(_ snapshot: LiveCaptionSnapshot) {
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)
        }
    }

    /// Finish all open caption streams. Called from `stop()` so any
    /// consumer's `for await` loop drains and exits — without this, a
    /// test's `Task { for await ... }` could outlive the actor.
    private func finishAllSnapshotStreams() {
        for continuation in snapshotContinuations.values {
            continuation.finish()
        }
        snapshotContinuations.removeAll()
    }

    // MARK: Internal — claim + receive

    private func beginClaim(attempt: Int) async {
        nextGeneration += 1
        let generation = nextGeneration
        let claimTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performClaim(generation: generation, attempt: attempt)
        }
        lifecycle = .claiming(generation: generation, claimTask: claimTask)
        trace("phase", "to=\(Self.snapshotTag(lifecycle.snapshot))")
    }

    private func performClaim(generation: Int, attempt: Int) async {
        trace("claim.begin", "attempt=\(attempt)")
        // Snapshot the connector before the await so we don't re-touch
        // actor state across the suspension.
        let connector = self.connector
        let language = self.language
        let mode = self.mode

        do {
            DiagnosticsLog.event(
                "live-caption",
                "claim.start mode=\(Self.modeLabel(mode)) language=\(language) attempt=\(attempt)"
            )
            let claim = try await connector.claimSession(mode: mode, language: language)
            DiagnosticsLog.event(
                "live-caption",
                "claim.success mode=\(Self.modeLabel(mode)) session=\(DiagnosticsLog.sanitize(claim.sessionId, maxLength: 64))"
            )
            // Re-check after await — `stop()` may have advanced the
            // lifecycle while we were suspended.
            guard case .claiming(let currentGeneration, _) = lifecycle,
                  currentGeneration == generation else {
                return
            }
            // Record the server-issued realtime session id so subsequent
            // `trace(...)` lines can correlate against the server-side
            // proxy's `sid=` traces. Done BEFORE the socket open so a
            // crash inside `openSocket` still surfaces the sid.
            lastClaimedSessionId = claim.sessionId
            trace("claim.success", "sid=\(claim.sessionId)")

            let socket = try await connector.openSocket(for: claim)
            // Same re-check — claim succeeded but the lifecycle may
            // have moved during the (possibly long) socket open.
            guard case .claiming(let stillCurrentGeneration, _) = lifecycle,
                  stillCurrentGeneration == generation else {
                socket.cancel(code: 1001, reason: nil)
                return
            }

            // Seed the stall-watchdog reference clock under actor
            // isolation BEFORE we spawn either task. Both tasks read
            // `connectionStartedAt` to compute "seconds since the
            // session opened" when no inbound has arrived yet; without
            // this seed the watchdog could observe `nil` on its first
            // tick and crash on a force-unwrap, or the receive loop's
            // belated init could race the watchdog's first probe.
            connectionStartedAt = Date()
            lastInboundTranscriptAt = nil
            voicedAudioBufferCountSinceInbound = 0
            // Manual-commit window resets per socket so a new live
            // session doesn't try to commit bytes that belonged to
            // the previous session (Codex Finding #5).
            hasUncommittedAudio = false
            uncommittedAudioByteCount = 0
            didLogFirstAudioSend = false
            didLogFirstInboundEvent = false
            // Context-hint guard resets per socket. The new live
            // session must observe `session.created` before we send
            // the hint, and the per-socket guard ensures we don't
            // double-send when a `session.created` arrives twice on
            // the same socket. Mirrors the legacy class's
            // `didSendContextHint = false` reset on reconnect-ready.
            didSendContextHint = false
            pendingContextHintSend = false

            let receiveTask = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.runReceiveLoop(socket: socket, generation: generation)
            }
            let watchdogTask = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.runStallWatchdogLoop(socket: socket, generation: generation)
            }
            // Stamp the live-open instant so drop traces can compute
            // `sinceOpenMs`. Cleared on reconnect / stop.
            liveOpenedAt = Date()
            lifecycle = .live(
                socket: socket,
                generation: generation,
                receiveTask: receiveTask,
                watchdogTask: watchdogTask
            )
            trace("phase", "to=live")
            DiagnosticsLog.event(
                "live-caption",
                "socket.live mode=\(Self.modeLabel(mode)) generation=\(generation) pendingAudio=\(pendingAudio.count)"
            )
            // Drain any audio captured while we were claiming / opening
            // the socket. The flush is performed on the actor so a
            // concurrent stop()/reconnectNow() can race in and the
            // identity guard inside `flushPendingAudio` will short-
            // circuit cleanly.
            await flushPendingAudio(socket: socket, generation: generation)
        } catch {
            // Re-check before scheduling a retry so a concurrent
            // `stop()` short-circuits the reconnect.
            guard case .claiming(let currentGeneration, _) = lifecycle,
                  currentGeneration == generation else {
                return
            }
            // Map the error onto an HTTP status when possible — the
            // proxy returns 429 here under the reconnect-storm scenario
            // we're investigating (suspect #2), so making the status
            // a first-class field in the trace lets the server-side log
            // join across `sid=` and the client trace by status.
            if case let RecappiAPIError.http(statusCode, _) = error {
                trace("claim.error", "status=\(statusCode) err=\(DiagnosticsLog.errorSummary(error))")
            } else {
                trace("claim.error", "status=-1 err=\(DiagnosticsLog.errorSummary(error))")
            }
            DiagnosticsLog.error(
                "live-caption",
                "claim.failed mode=\(Self.modeLabel(mode)) attempt=\(attempt) \(DiagnosticsLog.errorSummary(error))"
            )
            publishSnapshot(.statusOnly(phase: .failed, message: "Live captions are reconnecting…"))
            await scheduleReconnect(after: error, attempt: attempt)
        }
    }

    /// Recurring stall-watchdog loop. Spawned alongside the receive
    /// task when the lifecycle enters `.live`; cancelled when the
    /// `.live` case is left (stop / reconnect / terminal). Sleeps for
    /// `stallWatchdogInterval` between probes, then re-checks identity
    /// before invoking `runStallWatchdogProbe`. The probe handles the
    /// threshold gate + ping + reconnect/skip verdict.
    private func runStallWatchdogLoop(socket: RealtimeSocket, generation: Int) async {
        while !Task.isCancelled {
            let interval = stallWatchdogInterval
            let nanoseconds = UInt64(max(interval, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            if Task.isCancelled { return }
            // Bail if the lifecycle has moved past this socket — a
            // late wakeup must never probe a rotated-out connection.
            guard isCurrent(socket: socket, generation: generation) else { return }
            let voiced = voicedAudioBufferCountSinceInbound
            let lastInboundReference = lastInboundTranscriptAt ?? connectionStartedAt ?? Date()
            let quietFor = Date().timeIntervalSince(lastInboundReference)
            _ = await runStallWatchdogProbe(
                socket: socket,
                generation: generation,
                voicedBuffersSinceInbound: voiced,
                secondsSinceLastInbound: quietFor
            )
        }
    }

    private func runReceiveLoop(socket: RealtimeSocket, generation: Int) async {
        // Stall counters are initialised in `performClaim` before this
        // task is spawned so the watchdog and receive loop both see a
        // consistent baseline at task start.
        while !Task.isCancelled {
            // Verbose per-iter trace fires before suspending on
            // `socket.receive()` — guarded behind `verboseOnly` so it
            // costs nothing in steady state when the flag is off.
            trace("ws.recv.iter", verboseOnly: true)
            do {
                let message = try await socket.receive()
                guard isCurrent(socket: socket, generation: generation) else { return }
                // Cheap event-type derivation for the verbose recv
                // trace: peek at the message body without re-parsing the
                // whole event (the canonical parse happens inside
                // `handleReceiveSuccess`). When parsing isn't trivial,
                // fall back to a bytes count so the trace always carries
                // SOME shape information.
                if Diagnostics.verboseRealtime {
                    let typeTag = Self.peekReceiveType(message: message)
                    trace("ws.recv", "type=\(typeTag)", verboseOnly: true)
                }
                // A server `{"type":"error"}` event arrives through the
                // success arm — `receive()` itself never throws on a
                // server-side application error. If `handleReceiveSuccess`
                // signals an upstream-reported failure, escalate through
                // the same reconnect path the catch arm uses (Codex
                // Finding #8).
                if let serverError = handleReceiveSuccess(message: message) {
                    guard isCurrent(socket: socket, generation: generation) else { return }
                    if let evt = serverError as? RealtimeServerEventError {
                        trace(
                            "server.error",
                            "type='\(Self.tagString(evt.serverType))' code='\(Self.tagString(evt.serverCode))' message='\(DiagnosticsLog.sanitize(evt.message, maxLength: 240))'"
                        )
                    }
                    trace(
                        "ws.drop",
                        "code=\(socket.closeCode) reason='\(Self.closeReasonString(socket.closeReason))' sinceOpenMs=\(sinceOpenMs()) cause=server.error"
                    )
                    await scheduleReconnect(after: serverError, attempt: 1)
                    return
                }
                // Push the context hint as soon as the upstream is
                // ready (`session.created` / `transcription_session.created`
                // observed in `handleReceiveSuccess`). The send happens
                // here — not inside the receive handler — so we keep
                // `handleReceiveSuccess` synchronous and don't have to
                // ripple `async` through the test seam
                // `ingestReceiveEventJSONForTesting`.
                if shouldSendContextHint() {
                    guard isCurrent(socket: socket, generation: generation) else { return }
                    await sendContextHintIfNeeded(on: socket)
                }
            } catch {
                // Identity guard: a late buffered failure on a rotated-
                // out socket must not tear down the fresh one. This is
                // the structural fix for Codex Finding #3.
                guard isCurrent(socket: socket, generation: generation) else { return }
                // Terminal close codes (4000-4009) signal a server-side
                // teardown that won't recover by reconnecting. Mirror
                // the legacy class's `isTerminalCloseCode` semantics.
                let rawCode = socket.closeCode
                let errDescription = DiagnosticsLog.sanitize(String(describing: error), maxLength: 240)
                trace(
                    "ws.drop",
                    "code=\(rawCode) reason='\(Self.closeReasonString(socket.closeReason))' sinceOpenMs=\(sinceOpenMs()) cause=receive.throw err='\(errDescription)'"
                )
                if Self.isTerminalCloseCode(rawCode) {
                    await transitionToTerminalStop(rawCode: rawCode, reason: socket.closeReason)
                    return
                }
                await scheduleReconnect(after: error, attempt: 1)
                return
            }
        }
    }

    /// Compute the elapsed time since the lifecycle entered `.live`.
    /// Returns 0 when `liveOpenedAt` is unset (we already exited live
    /// or never reached it), which keeps the trace shape uniform.
    private func sinceOpenMs() -> Int {
        guard let openedAt = liveOpenedAt else { return 0 }
        let elapsed = Date().timeIntervalSince(openedAt)
        return max(0, Int(elapsed * 1000))
    }

    /// Decode the optional close-reason payload into a sanitized
    /// short string. Empty / undecodable returns `""` so the trace
    /// payload's `reason='...'` slot is always parseable.
    private static func closeReasonString(_ reason: Data?) -> String {
        guard let reason,
              let text = String(data: reason, encoding: .utf8),
              !text.isEmpty else {
            return ""
        }
        return DiagnosticsLog.sanitize(text, maxLength: 120)
    }

    /// Sanitize an optional short tag (server error type/code) for trace
    /// payloads. Returns empty string when the value is nil/empty so the
    /// `field='...'` slot is always present and parseable.
    private static func tagString(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return DiagnosticsLog.sanitize(value, maxLength: 64)
    }

    /// Peek at a received WebSocket message and return a short tag
    /// (event type for text frames, byte count for binary frames). We
    /// avoid a full JSON decode here — the receive loop already parses
    /// the message in `handleReceiveSuccess`, and the trace's job is
    /// just to fingerprint the frame so verbose logs are scannable.
    private static func peekReceiveType(message: RealtimeSocketMessage) -> String {
        switch message {
        case .text(let text):
            if let typeValue = extractType(fromTextFrame: text) {
                return DiagnosticsLog.sanitize(typeValue, maxLength: 64)
            }
            return "text(bytes=\(text.utf8.count))"
        case .data(let data):
            return "data(bytes=\(data.count))"
        }
    }

    /// Lightweight scan for the top-level `"type"` field of a JSON
    /// event. Returns `nil` if the frame doesn't look like a JSON
    /// object with a string `type`. Cheap by design: bails on the
    /// first match without allocating a `JSONDecoder` (the verbose
    /// trace fires per-receive — full decoding here would be wasteful
    /// when the next line in the receive loop does the canonical
    /// decode).
    private static func extractType(fromTextFrame text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let type = dict["type"] as? String else {
            return nil
        }
        return type
    }

    /// Map a successful receive into transcript / bilingual state and
    /// publish a snapshot when something visible changed. The parser
    /// covers the same event types the legacy class handles in
    /// `consume(_:from:)`; identity guarding is the caller's job
    /// (`runReceiveLoop` already short-circuits on stale sockets).
    ///
    /// Returns a non-nil `Error` when the server delivered an
    /// application-level error event (`{"type":"error"}`). The
    /// caller (`runReceiveLoop`) routes that into `scheduleReconnect`
    /// so the lifecycle exits `.live` instead of spinning back into
    /// `await socket.receive()`. This is the Codex Finding #8 fix —
    /// previously this case only published a status snapshot and the
    /// lifecycle stayed in `.live` forever.
    @discardableResult
    private func handleReceiveSuccess(message: RealtimeSocketMessage) -> Error? {
        let payload: Data
        switch message {
        case .text(let text):
            payload = Data(text.utf8)
        case .data(let data):
            payload = data
        }
        guard let event = try? JSONDecoder().decode(RealtimeReceiveEvent.self, from: payload) else {
            return nil
        }
        logFirstInboundEventIfNeeded(event.type)
        switch event.type {
        case "session.created", "transcription_session.created":
            // Reset the stall counters so the watchdog waits for fresh
            // post-warmup traffic before considering the session
            // stalled.
            voicedAudioBufferCountSinceInbound = 0
            lastInboundTranscriptAt = Date()
            // Arm the context-hint sender. The actual `await
            // socket.send(...)` runs in the receive loop after this
            // handler returns so `handleReceiveSuccess` stays sync.
            pendingContextHintSend = true
        case "input_audio_buffer.committed":
            // OpenAI's Realtime API carries `previous_item_id` on the
            // `input_audio_buffer.committed` event (NOT on the
            // subsequent transcription delta/completed events). The
            // legacy `BackendRealtimeLiveCaptionTranscriber` used this
            // event as the primary ordering signal via
            // `registerCommittedItem`. Pre-register the transcript slot
            // with its predecessor link BEFORE any delta arrives so the
            // timeline ordering is established at commit time. Without
            // this, out-of-order items fall back to network-arrival
            // ordering instead of the conversational ordering OpenAI
            // intends. See Pipecat's authoritative event schema:
            // https://reference-server.pipecat.ai/...
            _ = ensureTranscriptItem(
                event.transcriptItemKey,
                previousItemID: event.previousItemID
            )
        case "conversation.item.input_audio_transcription.delta":
            if let snapshot = appendTranscriptDelta(
                event.delta,
                key: event.transcriptItemKey,
                previousItemID: event.previousItemID
            ) {
                markTranscriptOutput()
                publishSnapshot(snapshot)
            }
        case "conversation.item.input_audio_transcription.completed":
            if let snapshot = completeTranscript(
                event.transcript,
                key: event.transcriptItemKey,
                previousItemID: event.previousItemID
            ) {
                markTranscriptOutput()
                publishSnapshot(snapshot)
            }
        case "session.input_transcript.delta":
            if let delta = event.delta, !delta.isEmpty,
               let snapshot = ingestBilingualDelta(.source, text: delta) {
                markTranscriptOutput()
                publishSnapshot(snapshot)
            }
        case "session.output_transcript.delta":
            if let delta = event.delta, !delta.isEmpty,
               let snapshot = ingestBilingualDelta(.translation, text: delta) {
                markTranscriptOutput()
                publishSnapshot(snapshot)
            }
        case "error":
            // Tear down so the lifecycle schedules a reconnect through
            // the normal failure path. We publish the user-facing
            // failure snapshot here, then return the error so the
            // receive loop transitions out of `.live`.
            let message = event.error?.message ?? "Realtime session failed."
            publishSnapshot(.statusOnly(phase: .failed, message: message))
            return RealtimeServerEventError(
                message: message,
                serverType: event.error?.type,
                serverCode: event.error?.code
            )
        default:
            break
        }
        return nil
    }

    private func markTranscriptOutput() {
        voicedAudioBufferCountSinceInbound = 0
        lastInboundTranscriptAt = Date()
    }

    private func logFirstInboundEventIfNeeded(_ type: String) {
        guard !didLogFirstInboundEvent else { return }
        didLogFirstInboundEvent = true
        DiagnosticsLog.event(
            "live-caption",
            "inbound.first_event mode=\(Self.modeLabel(mode)) type=\(type)"
        )
    }

    private func appendTranscriptDelta(
        _ rawDelta: String?,
        key: RealtimeTranscriptKey,
        previousItemID: String?
    ) -> LiveCaptionSnapshot? {
        guard let delta = rawDelta, !delta.isEmpty else { return nil }
        let existing = ensureTranscriptItem(key, previousItemID: previousItemID)
        guard !existing.isFinal else { return nil }
        transcriptItems[key] = existing.appending(delta)
        return publishTimelineSnapshot()
    }

    private func completeTranscript(
        _ rawTranscript: String?,
        key: RealtimeTranscriptKey,
        previousItemID: String?
    ) -> LiveCaptionSnapshot? {
        let existing = ensureTranscriptItem(key, previousItemID: previousItemID)
        let text = (rawTranscript ?? existing.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        transcriptItems[key] = existing.replacingText(text, isFinal: true)
        return publishTimelineSnapshot()
    }

    /// Ensure a transcript item exists for `key`. If the item is being
    /// inserted into the timeline for the first time AND a
    /// `previousItemID` was supplied AND that prior item is already on
    /// the timeline, insert the new key immediately after it. Otherwise
    /// append at the end. Resolves Codex Finding #10: OpenAI orders
    /// items via `previous_item_id` rather than network arrival order;
    /// the legacy class tracked this through `pendingPreviousItemIDByKey`
    /// + `moveTranscriptItemLocked`.
    ///
    /// In production the ordering signal arrives on
    /// `input_audio_buffer.committed` (the OpenAI Realtime event that
    /// actually carries `previous_item_id`). The delta/completed paths
    /// also pass `previousItemID` defensively — they are a no-op when
    /// the slot was already pre-registered by the committed handler,
    /// and they preserve test seams (e.g.
    /// `ingestReceiveEventJSONForTesting`) that drive completed events
    /// directly without a prior commit.
    private func ensureTranscriptItem(
        _ key: RealtimeTranscriptKey,
        previousItemID: String?
    ) -> RealtimeTranscriptItem {
        if let item = transcriptItems[key] {
            // First-seen-but-already-buffered case: the item may have
            // been pending a previous-item placement that wasn't yet
            // resolved (the referenced prior arrived later). Try again
            // now that more keys may be on the timeline.
            resolvePendingPlacement(for: key)
            return item
        }
        fallbackSequence += 1
        let item = RealtimeTranscriptItem(text: "", isFinal: false, sequence: fallbackSequence)
        transcriptItems[key] = item
        // Default placement: append at the end. If a `previous_item_id`
        // is supplied AND we already have that prior item on the
        // timeline, slot the new key in immediately after it. Otherwise
        // remember the link so a later-arriving prior item can pull
        // this one into the correct slot.
        transcriptTimeline.append(key)
        if let previousItemID, !previousItemID.isEmpty {
            if moveTranscriptItem(key, afterItemID: previousItemID) {
                pendingPreviousItemIDByKey[key] = nil
            } else {
                pendingPreviousItemIDByKey[key] = previousItemID
            }
        }
        return item
    }

    /// Move `key` to immediately after the last timeline entry whose
    /// `itemID` matches `previousItemID`. Returns `true` when the
    /// move happened. Mirrors the legacy class's
    /// `moveTranscriptItemLocked` so the placement semantics are
    /// byte-identical across the refactor boundary.
    @discardableResult
    private func moveTranscriptItem(
        _ key: RealtimeTranscriptKey,
        afterItemID previousItemID: String
    ) -> Bool {
        guard let currentIndex = transcriptTimeline.firstIndex(of: key),
              let previousIndex = transcriptTimeline.lastIndex(where: { $0.itemID == previousItemID }) else {
            return false
        }
        let removed = transcriptTimeline.remove(at: currentIndex)
        let adjustedPreviousIndex = currentIndex < previousIndex ? previousIndex - 1 : previousIndex
        transcriptTimeline.insert(
            removed,
            at: min(adjustedPreviousIndex + 1, transcriptTimeline.count)
        )
        return true
    }

    /// Resolve a pending placement once the referenced prior item is
    /// known to be on the timeline. Called both when the key is
    /// re-seen (subsequent delta) and after each new key is appended
    /// (via `resolveAllPendingPlacements`).
    private func resolvePendingPlacement(for key: RealtimeTranscriptKey) {
        guard let previousItemID = pendingPreviousItemIDByKey[key],
              !previousItemID.isEmpty else { return }
        if moveTranscriptItem(key, afterItemID: previousItemID) {
            pendingPreviousItemIDByKey[key] = nil
        }
    }

    /// Walk the pending-placement table after a timeline mutation and
    /// retry every entry. Cheap: bounded by the number of unresolved
    /// out-of-order items, which is typically <= 1 in practice.
    private func resolveAllPendingPlacements() {
        let pendingKeys = Array(pendingPreviousItemIDByKey.keys)
        for key in pendingKeys {
            resolvePendingPlacement(for: key)
        }
    }

    private func publishTimelineSnapshot() -> LiveCaptionSnapshot? {
        // Resolve any deferred previous-item placements before rendering.
        // A delta that arrived for an item whose `previous_item_id`
        // referenced an item we hadn't seen yet may now be slottable
        // into its correct position. Mirrors the legacy class's
        // `resolveAllPendingPlacementsLocked` call site.
        resolveAllPendingPlacements()
        // Keep the nonisolated mirror in sync with every transcript
        // mutation. The receive loop is the only path that mutates
        // `transcriptTimeline` / `transcriptItems` during a live
        // session, and it always finishes through here.
        updateDrainMirror()
        let segments = displaySegments()
        guard !segments.isEmpty else { return nil }
        if segments == lastPublishedSegments { return nil }
        lastPublishedSegments = segments
        let allFinal = segments.allSatisfy(\.isFinal)
        return LiveCaptionSnapshot(
            phase: .listening,
            segments: segments,
            allSegmentsFinal: allFinal,
            message: nil
        )
    }

    /// Build a flat list of segments from the transcript timeline.
    /// Mirrors the legacy class's `displaySegmentsLocked` so the
    /// production rendering — short items joined into one display
    /// segment, sentence-boundary breaks, and a soft cap that splits
    /// long unpunctuated runs — survives the move onto the actor.
    private func displaySegments() -> [LiveCaptionSegment] {
        struct DisplaySegment {
            let id: String
            var sourceText: String
            var isFinal: Bool
            let sequence: Int

            var liveCaptionSegment: LiveCaptionSegment {
                LiveCaptionSegment(
                    id: id,
                    sourceText: sourceText,
                    translatedText: nil,
                    isFinal: isFinal,
                    sequence: sequence
                )
            }
        }

        var segments: [LiveCaptionSegment] = []
        var current: DisplaySegment?

        for key in transcriptTimeline {
            guard let item = transcriptItems[key] else { continue }
            let normalized = Self.normalizedSegmentText(item.text)
            guard !normalized.isEmpty else { continue }

            if var active = current {
                if Self.shouldStartNewDisplaySegment(
                    after: active.sourceText,
                    beforeAppending: normalized
                ) {
                    segments.append(active.liveCaptionSegment)
                    current = DisplaySegment(
                        id: Self.segmentIdentifier(for: key),
                        sourceText: normalized,
                        isFinal: item.isFinal,
                        sequence: item.sequence
                    )
                } else {
                    Self.appendDisplayText(normalized, to: &active.sourceText)
                    active.isFinal = active.isFinal && item.isFinal
                    current = active
                }
            } else {
                current = DisplaySegment(
                    id: Self.segmentIdentifier(for: key),
                    sourceText: normalized,
                    isFinal: item.isFinal,
                    sequence: item.sequence
                )
            }
        }

        if let current {
            segments.append(current.liveCaptionSegment)
        }
        return segments
    }

    /// Stable id used by the UI / translation cache. Combining
    /// `item_id` and `content_index` keeps the id unique even when one
    /// Realtime item carries multiple content slots.
    private static func segmentIdentifier(for key: RealtimeTranscriptKey) -> String {
        key.contentIndex == 0
            ? key.itemID
            : "\(key.itemID)#\(key.contentIndex)"
    }

    /// Collapse runs of whitespace into single spaces. Segment-level
    /// rendering joins segments with `\n` (or richer attribute breaks)
    /// in the UI layer, so each segment text stays single-line.
    private static func normalizedSegmentText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func shouldStartNewDisplaySegment(
        after text: String,
        beforeAppending fragment: String
    ) -> Bool {
        if shouldStartNewDisplaySegmentAfterSentenceBoundary(text) {
            return true
        }
        let proposedLength = text.count + fragment.count
        let softLimit = displaySegmentSoftLimit(for: text + fragment)
        return text.count >= softLimit || proposedLength >= softLimit * 2
    }

    private static func shouldStartNewDisplaySegmentAfterSentenceBoundary(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return last.isLiveCaptionSentenceEnding
    }

    private static func displaySegmentSoftLimit(for text: String) -> Int {
        text.contains(where: \.isCJK) ? 72 : 140
    }

    private static func appendDisplayText(_ fragment: String, to result: inout String) {
        guard !fragment.isEmpty else { return }
        guard let previous = result.last, let next = fragment.first else {
            result.append(fragment)
            return
        }
        if shouldInsertDisplaySpace(between: previous, and: next) {
            result.append(" ")
        }
        result.append(fragment)
    }

    private static func shouldInsertDisplaySpace(between previous: Character, and next: Character) -> Bool {
        if previous.isWhitespace || next.isWhitespace { return false }
        if next.isPunctuation || next.isSymbol { return false }
        if previous.isPunctuation || previous.isSymbol { return true }
        if previous.isCJK || next.isCJK { return false }
        return true
    }

    private func ingestBilingualDelta(_ stream: RealtimeBilingualStream, text: String) -> LiveCaptionSnapshot? {
        guard let builder = bilingualBuilder else { return nil }
        builder.append(stream: stream, delta: text)
        // Keep the nonisolated mirror in sync with the bilingual
        // builder's latest state. Same rationale as
        // `publishTimelineSnapshot()`'s mirror call.
        updateDrainMirror()
        let segments = builder.snapshot()
        guard segments != lastPublishedSegments else { return nil }
        lastPublishedSegments = segments
        let allFinal = segments.allSatisfy(\.isFinal)
        return LiveCaptionSnapshot(
            phase: .listening,
            segments: segments,
            allSegmentsFinal: allFinal,
            message: nil
        )
    }

    /// Terminal close handler. Transitions directly to `.stopped` (no
    /// reconnect retry) and surfaces a status snapshot. The legacy
    /// class did the same via the `.terminal` decision branch in
    /// `handleConnectionFailure`.
    private func transitionToTerminalStop(rawCode: Int, reason: Data?) async {
        let message = Self.terminalCloseUserMessage(rawCloseCode: rawCode, reason: reason)
        publishSnapshot(.statusOnly(phase: .failed, message: message))
        lifecycle = .stopped
        trace("phase", "to=\(Self.snapshotTag(lifecycle.snapshot))")
        // Clear per-session diagnostic state so the next `start()`
        // doesn't carry the stale sid / openedAt into a fresh
        // lifecycle (Task C).
        lastClaimedSessionId = nil
        liveOpenedAt = nil
        finishAllSnapshotStreams()
    }

    static func isTerminalCloseCode(_ rawValue: Int) -> Bool {
        rawValue >= 4000 && rawValue <= 4009
    }

    static func terminalCloseUserMessage(rawCloseCode: Int, reason: Data?) -> String {
        if rawCloseCode == 4000 {
            return "字幕已被另一台设备接管"
        }
        if let reason,
           let text = String(data: reason, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "字幕服务已停止：\(text)"
        }
        return "字幕服务已停止"
    }

    // MARK: Stall watchdog (Phase 3c.2)

    /// Quiet-window before the watchdog probes the socket. Raised from
    /// 8 s to 20 s in the legacy class so legitimate low-speech
    /// intervals no longer trip the reconnect path. We re-use the same
    /// threshold here.
    static let stallNoOutputThreshold: TimeInterval = 20
    /// Voiced audio buffers required before we believe we've actually
    /// been talking.
    static let stallMinimumVoicedBuffers = 16
    static let stallPingTimeout: TimeInterval = 5
    /// How often the watchdog probes the socket once `.live` is
    /// established. Matches the legacy
    /// `BackendRealtimeLiveCaptionTranscriber.stallWatchdogInterval`.
    static let defaultStallWatchdogInterval: TimeInterval = 3

    /// Override-able interval for the recurring watchdog probe. Defaults
    /// to the production value; tests trim it via the DEBUG seam below
    /// so the probe fires inside a unit-test budget.
    private var stallWatchdogInterval: TimeInterval = RealtimeLiveCaptionActor.defaultStallWatchdogInterval
    /// Override-able voiced-buffer threshold used by the watchdog skip
    /// gate. Production code keeps it at the static default; tests can
    /// lower it (often to 0) so the probe fires deterministically.
    private var stallWatchdogVoicedBuffers: Int = RealtimeLiveCaptionActor.stallMinimumVoicedBuffers
    /// Override-able "seconds since last inbound" threshold used by the
    /// watchdog skip gate. Same testing rationale as the buffer
    /// threshold.
    private var stallWatchdogSecondsSinceInbound: TimeInterval = RealtimeLiveCaptionActor.stallNoOutputThreshold
    /// Override-able ping timeout used inside `runStallWatchdogProbe`.
    /// Defaults to the static production value; tests use a small
    /// value so the timeout arm wins the race deterministically.
    private var stallWatchdogPingTimeout: TimeInterval = RealtimeLiveCaptionActor.stallPingTimeout

    /// Probe outcome. Mirrors the legacy
    /// `StallWatchdogOutcomeForTesting` enum so callers (production +
    /// tests) get the same vocabulary for stall-handling decisions.
    enum StallWatchdogOutcome: Equatable {
        case skipped
        case pingedAndRecovered
        case pingFailedAndReconnected
    }

    /// Run the stall-watchdog probe against the supplied socket /
    /// generation pair. The actor uses this internally inside the
    /// `.live` task's watchdog Task; tests drive it directly through
    /// `runStallWatchdogProbeForTesting`. Identity guards are applied
    /// before the verdict mutates state so a stale verdict can't tear
    /// down the fresh socket — see the legacy class's
    /// `applyStallPingOutcome` for the architecture-analysis writeup.
    private func runStallWatchdogProbe(
        socket: RealtimeSocket,
        generation: Int,
        voicedBuffersSinceInbound: Int,
        secondsSinceLastInbound: TimeInterval
    ) async -> StallWatchdogOutcome {
        // Pre-ping identity guard + cancellation check. The recurring
        // watchdog loop already bails before entering the probe on a
        // stale lifecycle, but the actor is reentrant: a concurrent
        // stop() can interleave between the loop's check and this
        // call's entry. The legacy `evaluateStallWatchdog` performed
        // the same identity check before issuing the ping for the
        // same reason.
        guard !Task.isCancelled,
              isCurrent(socket: socket, generation: generation) else {
            return .skipped
        }
        // Threshold gate. The legacy class folds this into the
        // `evaluateStallWatchdog` capture; we keep it explicit so tests
        // can pin both the skip and the trigger paths.
        guard voicedBuffersSinceInbound >= stallWatchdogVoicedBuffers,
              secondsSinceLastInbound >= stallWatchdogSecondsSinceInbound else {
            return .skipped
        }
        trace("ws.watchdog.fire", "quietForSec=\(Int(secondsSinceLastInbound))")

        // Race the ping against a timeout. `withTaskGroup` would await
        // every child before exiting, which deadlocks the probe when
        // `socket.sendPing()` never resumes (half-open socket: the
        // pong callback never arrives, the continuation behind
        // `sendPing()` is leaked but never resolved). We need a
        // first-resume-wins arbiter that lets the timeout arm return
        // even if the ping continuation is permanently orphaned. The
        // legacy `PingRace` did exactly this via a lock + a
        // single-shot continuation.
        let pingTimeout = stallWatchdogPingTimeout
        let pingResult: Result<Void, Error> = await Self.racePing(
            sendPing: { try await socket.sendPing() },
            timeout: pingTimeout
        )

        // Identity guard before applying the verdict. The legacy
        // class's `applyStallPingOutcome` had to do this under the
        // input queue's `sync` block; the actor version is the same
        // pattern-match it does for every receive.
        guard case .live(let current, let currentGeneration, _, _) = lifecycle,
              current === socket,
              currentGeneration == generation else {
            // Stale — drop the verdict.
            return pingResult.isSuccess ? .pingedAndRecovered : .pingFailedAndReconnected
        }

        switch pingResult {
        case .success:
            voicedAudioBufferCountSinceInbound = 0
            lastInboundTranscriptAt = Date()
            return .pingedAndRecovered
        case .failure(let error):
            await scheduleReconnect(after: error, attempt: 1)
            return .pingFailedAndReconnected
        }
    }

    /// Pattern-match guard used by the receive loop. Extracted so the
    /// DEBUG seam below can drive the production identity check
    /// without re-implementing it inside the test mock.
    private func isCurrent(socket: RealtimeSocket, generation: Int) -> Bool {
        guard case .live(let current, let currentGeneration, _, _) = lifecycle else {
            return false
        }
        return current === socket && currentGeneration == generation
    }

    /// First-resume-wins race between a ping and a timeout. Unlike
    /// `withTaskGroup`, this MUST NOT wait for the loser to finish:
    /// when `sendPing()` is wedged on a half-open socket the
    /// underlying continuation never resolves and would block the
    /// caller indefinitely. We give both arms a single-shot
    /// `PingRace` arbiter that ignores the late resume — the leaked
    /// ping task continues to live until the URLSession task is
    /// cancelled (which happens during the caller's reconnect path)
    /// but the watchdog itself returns promptly.
    nonisolated static func racePing(
        sendPing: @Sendable @escaping () async throws -> Void,
        timeout: TimeInterval
    ) async -> Result<Void, Error> {
        let arbiter = PingRace()
        // Spawn the ping in a detached task so the awaiter doesn't
        // structurally own it. If `sendPing()` never resumes, the task
        // simply leaks — that's strictly better than deadlocking the
        // watchdog (which is the entire bug this race is fixing).
        let pingTask = Task.detached(priority: .userInitiated) { @Sendable in
            do {
                try await sendPing()
                arbiter.resolve(.success(()))
            } catch {
                arbiter.resolve(.failure(error))
            }
        }
        // Same for the timeout arm — detached so a late ping resume
        // doesn't structurally wait on it.
        let timeoutTask = Task.detached(priority: .userInitiated) { @Sendable in
            try? await Task.sleep(
                nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000)
            )
            arbiter.resolve(.failure(NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "ws.ping.timeout"]
            )))
        }
        let outcome = await arbiter.wait()
        // Cancel the loser so it observes cancellation and exits
        // promptly. The ping task can ignore cancellation (the
        // URLSessionWebSocketTask continuation is callback-driven);
        // that's acceptable, the leak is bounded and the socket gets
        // torn down on the imminent reconnect anyway.
        pingTask.cancel()
        timeoutTask.cancel()
        return outcome
    }

    /// Single-shot continuation arbiter. The first call to
    /// `resolve(_:)` wakes the awaiter; subsequent calls are dropped.
    /// Lifted from the legacy class's `PingRace` so the behaviour
    /// matches.
    final class PingRace: @unchecked Sendable {
        private let lock = NSLock()
        private var resolved = false
        private var pendingResult: Result<Void, Error>?
        private var continuation: CheckedContinuation<Result<Void, Error>, Never>?

        func resolve(_ result: Result<Void, Error>) {
            lock.lock()
            if resolved {
                lock.unlock()
                return
            }
            resolved = true
            if let continuation = self.continuation {
                self.continuation = nil
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                pendingResult = result
                lock.unlock()
            }
        }

        func wait() async -> Result<Void, Error> {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Error>, Never>) in
                lock.lock()
                if let pending = pendingResult {
                    pendingResult = nil
                    lock.unlock()
                    continuation.resume(returning: pending)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func scheduleReconnect(after error: Error, attempt: Int) async {
        let delay = reconnectDelay(forAttempt: attempt)
        trace("reconnect.schedule", "attempt=\(attempt) delayMs=\(Int(delay * 1000))")
        lifecycle = .reconnecting(
            generation: nextGeneration,
            attempt: attempt,
            scheduledAt: Date(),
            delay: delay
        )
        trace("phase", "to=\(Self.snapshotTag(lifecycle.snapshot))")
        // The .live window is over: clear the open-instant so a future
        // drop trace doesn't compute `sinceOpenMs` against a defunct
        // socket. `lastClaimedSessionId` deliberately stays — the next
        // claim will overwrite it, but until then traces continue to
        // identify which session we're reconnecting from.
        liveOpenedAt = nil
        // Audio captured pre-reconnect belongs to the failed session;
        // replaying it on the next live socket replays a window the
        // server already considered stalled / dropped. Wipe the queue
        // so the next .live transition starts from fresh frames only.
        pendingAudio.removeAll()
        // Manual-commit counters are session-scoped; the new socket
        // will start a clean window (Codex Finding #5).
        hasUncommittedAudio = false
        uncommittedAudioByteCount = 0
        _ = error
        // Sleep, then re-check before re-claiming so a concurrent
        // stop() during the delay drops us out.
        let nanoseconds = UInt64(delay * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
        guard case .reconnecting = lifecycle else { return }
        trace("reconnect.fire")
        await beginClaim(attempt: attempt + 1)
    }

    private func reconnectDelay(forAttempt attempt: Int) -> TimeInterval {
        let delays = configuration.reconnectDelays
        guard !delays.isEmpty else { return 0 }
        let bounded = max(0, min(attempt, delays.count - 1))
        return delays[bounded]
    }

    // MARK: Diagnostic trace helper (Task C)

    /// Emit one `rt-trace` entry into `DiagnosticsLog` carrying the
    /// current generation, claimed realtime session id, and lifecycle
    /// phase. Free-form `payload` is appended verbatim (callers
    /// pre-sanitize any server-supplied substrings via
    /// `DiagnosticsLog.sanitize(_:maxLength:)`).
    ///
    /// `verboseOnly` gates high-cadence call sites (audio send begin/end,
    /// receive-loop iter) on `Diagnostics.verboseRealtime`. The headline
    /// lifecycle / failure traces leave the flag at its default so they
    /// always reach the log.
    /// `payload` is `@autoclosure` so verbose-only call sites that
    /// interpolate per-frame state (e.g. `"bytes=\(payload.count)"`)
    /// don't pay the string-allocation cost when the verbose flag is
    /// off. The closure is invoked at most once, after the gate check.
    private func trace(
        _ event: String,
        _ payload: @autoclosure () -> String = "",
        verboseOnly: Bool = false
    ) {
        if verboseOnly && !Diagnostics.verboseRealtime { return }
        let resolved = payload()
        let gen = currentGenerationForTrace
        let sid = lastClaimedSessionId ?? "-"
        let phaseTag = Self.snapshotTag(lifecycle.snapshot)
        let suffix = resolved.isEmpty ? "" : " " + resolved
        DiagnosticsLog.event(
            "rt-trace",
            "sid=\(sid) gen=\(gen) phase=\(phaseTag) event=\(event)\(suffix)"
        )
    }

    /// Generation counter as observed from the current lifecycle case.
    /// `.created` and `.stopped` have no associated generation; we
    /// surface `nextGeneration` as a best-effort hint so the trace
    /// continues to carry a monotonically-increasing sequence number.
    private var currentGenerationForTrace: Int {
        switch lifecycle {
        case .created, .stopped:
            return nextGeneration
        case .claiming(let g, _):
            return g
        case .live(_, let g, _, _):
            return g
        case .reconnecting(let g, _, _, _):
            return g
        case .stopping:
            return nextGeneration
        }
    }

    /// Short tag for a `RealtimeLifecycleSnapshot`. Used inside the
    /// `rt-trace` line so each entry self-identifies which phase the
    /// actor was in when the event fired.
    private static func snapshotTag(_ snapshot: RealtimeLifecycleSnapshot) -> String {
        switch snapshot {
        case .created: return "created"
        case .claiming: return "claiming"
        case .live: return "live"
        case .reconnecting: return "reconnecting"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        }
    }

#if DEBUG
    /// Test seam: snapshot the current lifecycle case. Equatable so
    /// tests can assert on transitions without exposing the internal
    /// associated I/O handles.
    func lifecycleSnapshotForTesting() -> RealtimeLifecycleSnapshot {
        lifecycle.snapshot
    }

    /// Test seam: append entries directly so a test can pre-seed the
    /// transcript before calling `stop()`. Routes through the timeline
    /// the receive loop normally fills, so `drainEntries()` returns
    /// the same shape it would in production.
    func appendEntriesForTesting(_ entries: [LiveCaptionEntry]) {
        for entry in entries {
            fallbackSequence += 1
            let key = RealtimeTranscriptKey(
                itemID: "test-\(fallbackSequence)",
                contentIndex: 0
            )
            transcriptTimeline.append(key)
            transcriptItems[key] = RealtimeTranscriptItem(
                text: entry.text,
                isFinal: entry.isFinal,
                sequence: fallbackSequence
            )
        }
        // Keep the nonisolated drain mirror in sync with the seeded
        // timeline so a subsequent `drainEntriesNonblocking()` (or the
        // MainActor carryover bridge that calls it) observes these
        // entries without first having to enter actor isolation.
        updateDrainMirror()
    }

    /// Test seam: simulate a receive callback (success or failure)
    /// against a specific socket identity. Returns the lifecycle
    /// snapshot after the simulated handler runs so the test can
    /// assert that a stale receive does NOT advance the lifecycle.
    /// Calls into the same `isCurrent` guard the production receive
    /// loop uses — exactly the path bug #3 broke in the legacy class.
    func simulateReceiveOutcomeForTesting(
        socket: RealtimeSocket,
        generation: Int,
        outcome: Result<RealtimeSocketMessage, Error>
    ) async -> RealtimeLifecycleSnapshot {
        switch outcome {
        case .success:
            guard isCurrent(socket: socket, generation: generation) else {
                return lifecycle.snapshot
            }
            // Receive-side state mutations land in Phase 3; here we
            // simply confirm the guard executed and the lifecycle
            // remained unchanged.
            return lifecycle.snapshot
        case .failure(let error):
            guard isCurrent(socket: socket, generation: generation) else {
                return lifecycle.snapshot
            }
            await scheduleReconnect(after: error, attempt: 1)
            return lifecycle.snapshot
        }
    }

    /// Test seam: return (socket, generation) of the current `.live`
    /// case so tests can capture the live identity and compare it
    /// against a previously-captured (stale) one.
    func currentLiveIdentityForTesting() -> (socket: RealtimeSocket, generation: Int)? {
        guard case .live(let socket, let generation, _, _) = lifecycle else {
            return nil
        }
        return (socket, generation)
    }

    /// Test seam: feed an already-encoded PCM16 payload directly into
    /// the audio routing path. Production code goes through the
    /// nonisolated `append(sampleBuffer:)` trampoline; driving the
    /// actor through pre-encoded payloads lets the audio test suite
    /// assert routing, ordering, and back-pressure without hand-
    /// rolling `CMSampleBuffer` fixtures.
    func appendPCM16ForTesting(_ payload: Data) async {
        await ingestPCM16(payload)
    }

    /// Test seam: how many encoded frames are currently buffered
    /// pre-live. Used by the back-pressure tests.
    func bufferedAudioCountForTesting() -> Int {
        pendingAudio.count
    }

    /// Test seam: counter for frames dropped because the bounded queue
    /// was full. Used by the overflow test.
    func droppedAudioCountForTesting() -> Int {
        droppedAudioCount
    }

    /// Test seam: feed a parsed receive event straight into the
    /// receive handler. Returns the resulting timeline snapshot
    /// derived from the actor's current state — same shape the
    /// receive loop publishes through `captionSnapshots()` in
    /// production. Returns `nil` if the event produced no
    /// renderable timeline change (e.g. a non-text event or a
    /// duplicate-content delta).
    func ingestReceiveEventJSONForTesting(_ json: String) -> LiveCaptionSnapshot? {
        let beforeSegments = lastPublishedSegments
        handleReceiveSuccess(message: .text(json))
        let afterSegments = lastPublishedSegments
        if beforeSegments == afterSegments { return nil }
        let allFinal = afterSegments.allSatisfy(\.isFinal)
        return LiveCaptionSnapshot(
            phase: .listening,
            segments: afterSegments,
            allSegmentsFinal: allFinal,
            message: nil
        )
    }

    /// Test seam: drainEntries equivalent reachable from outside the
    /// actor without the I/O-bound `stop()` path. Lets tests assert on
    /// the saved-transcript shape without tearing down the actor.
    func drainEntriesForTesting() -> [LiveCaptionEntry] {
        drainEntries()
    }

    /// Test seam: drive the stall watchdog probe with explicit values
    /// for the inputs `evaluateStallWatchdog` would normally capture
    /// from internal state. Returns the same `StallWatchdogOutcome`
    /// the production code produces.
    func runStallWatchdogProbeForTesting(
        socket: RealtimeSocket,
        generation: Int,
        voicedBuffersSinceInbound: Int,
        secondsSinceLastInbound: TimeInterval,
        secondsSinceLastVoicedAudio: TimeInterval
    ) async -> StallWatchdogOutcome {
        _ = secondsSinceLastVoicedAudio
        return await runStallWatchdogProbe(
            socket: socket,
            generation: generation,
            voicedBuffersSinceInbound: voicedBuffersSinceInbound,
            secondsSinceLastInbound: secondsSinceLastInbound
        )
    }

    /// Test seam: replace the production watchdog cadence with a much
    /// shorter interval so a unit test can observe a ping fire within
    /// its time budget.
    func setStallWatchdogIntervalForTesting(_ interval: TimeInterval) {
        stallWatchdogInterval = max(0, interval)
    }

    /// Test seam: lower the watchdog skip-gate so the recurring probe
    /// fires on each tick without needing real voiced traffic. Tests
    /// that exercise the threshold gate directly use
    /// `runStallWatchdogProbeForTesting`.
    func setStallWatchdogThresholdsForTesting(
        voicedBuffers: Int,
        secondsSinceLastInbound: TimeInterval
    ) {
        stallWatchdogVoicedBuffers = max(0, voicedBuffers)
        stallWatchdogSecondsSinceInbound = max(0, secondsSinceLastInbound)
    }

    /// Test seam: shorten the ping timeout so a wedged ping resolves
    /// the probe quickly. Used by Finding #9's regression test which
    /// verifies the probe doesn't hang on a half-open socket.
    func setStallPingTimeoutForTesting(_ timeout: TimeInterval) {
        stallWatchdogPingTimeout = max(0, timeout)
    }

    /// Test seam: shorten the close-handshake timeout used inside
    /// `stop()` so a wedged peer doesn't pay the full 3-second
    /// production budget. Used by the Finding #6 regression tests.
    func setStopCloseHandshakeTimeoutForTesting(_ timeout: TimeInterval) {
        stopCloseHandshakeTimeout = max(0, timeout)
    }
#endif
}

// MARK: - Audio encoding (PCM16 little-endian)

/// PCM16 / 24 kHz / mono encoder shared by the actor and the legacy
/// class. Lifted into its own namespace so the actor's nonisolated
/// `append(sampleBuffer:)` can call into it without re-entering the
/// legacy class's static helpers (which are private). The conversion
/// pipeline is byte-for-byte the legacy `realtimePCMData(from:)` so the
/// production audio path stays identical when the actor takes over.
enum RealtimeAudioEncoder {
    static let targetSampleRate: Double = 24_000

    /// Rough RMS check used by the stall watchdog to distinguish
    /// voiced frames from silence. Byte-for-byte the legacy class's
    /// `containsLikelySpeech` so the threshold telemetry stays
    /// comparable across the refactor boundary.
    static func containsLikelySpeech(_ data: Data) -> Bool {
        let sampleStride = 64
        let minimumAverageMagnitude = 240
        var sampleCount = 0
        var magnitudeTotal = 0
        data.withUnsafeBytes { rawBuffer in
            guard let samples = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            let count = rawBuffer.count / MemoryLayout<Int16>.size
            guard count > 0 else { return }
            var index = 0
            while index < count {
                magnitudeTotal += Int(abs(Int32(samples[index])))
                sampleCount += 1
                index += sampleStride
            }
        }
        guard sampleCount > 0 else { return false }
        return magnitudeTotal / sampleCount >= minimumAverageMagnitude
    }

    static func pcm16Data(from sampleBuffer: CMSampleBuffer) -> Data? {
        if let direct = directHalfRatePCM16Data(from: sampleBuffer) {
            return direct
        }

        guard let source = floatingPCMBuffer(from: sampleBuffer),
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: true
              ) else {
            return nil
        }

        guard let converter = AVAudioConverter(from: source.format, to: targetFormat) else {
            return nil
        }
        let ratio = targetSampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * ratio) + 16)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        let inputState = RealtimeConverterInputState(source: source)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            inputState.next(status: status)
        }
        guard error == nil,
              converted.frameLength > 0,
              let data = converted.int16ChannelData else {
            return nil
        }

        let byteCount = Int(converted.frameLength) * Int(converted.format.streamDescription.pointee.mBytesPerFrame)
        return Data(bytes: data[0], count: byteCount)
    }

    /// Fast path for the dominant ScreenCaptureKit format: 48 kHz PCM
    /// into the 24 kHz mono PCM16 stream expected by Realtime. This
    /// keeps recording responsive by avoiding an `AVAudioConverter`
    /// allocation on every audio callback. Non-48 kHz or uncommon
    /// formats still fall back to the converter path above.
    private static func directHalfRatePCM16Data(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard sampleBuffer.isValid,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let asbd = asbdPointer.pointee
        guard abs(asbd.mSampleRate - (targetSampleRate * 2)) < 1 else {
            return nil
        }

        let channelCount = max(Int(asbd.mChannelsPerFrame), 1)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let outputFrameCount = frameCount / 2
        guard outputFrameCount > 0 else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let raw = dataPointer else {
            return nil
        }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        if isFloat, asbd.mBitsPerChannel == 32 {
            let sampleCount = min(totalLength / MemoryLayout<Float>.size, frameCount * channelCount)
            return raw.withMemoryRebound(to: Float.self, capacity: sampleCount) { source in
                var output = Data(count: outputFrameCount * MemoryLayout<Int16>.size)
                output.withUnsafeMutableBytes { rawOutput in
                    guard let target = rawOutput.bindMemory(to: Int16.self).baseAddress else { return }
                    var outputFrame = 0
                    if isNonInterleaved {
                        while outputFrame < outputFrameCount {
                            let firstFrame = outputFrame * 2
                            let secondFrame = firstFrame + 1
                            var mixed: Float = 0
                            var channel = 0
                            while channel < channelCount {
                                let channelBase = channel * frameCount
                                let firstIndex = channelBase + firstFrame
                                let secondIndex = channelBase + secondFrame
                                let first = firstIndex < sampleCount ? source[firstIndex] : 0
                                let second = secondIndex < sampleCount ? source[secondIndex] : 0
                                mixed += (first + second) * 0.5
                                channel += 1
                            }
                            target[outputFrame] = pcm16Sample(mixed / Float(channelCount))
                            outputFrame += 1
                        }
                    } else {
                        while outputFrame < outputFrameCount {
                            let firstBase = (outputFrame * 2) * channelCount
                            let secondBase = firstBase + channelCount
                            var mixed: Float = 0
                            var channel = 0
                            while channel < channelCount {
                                let firstIndex = firstBase + channel
                                let secondIndex = secondBase + channel
                                let first = firstIndex < sampleCount ? source[firstIndex] : 0
                                let second = secondIndex < sampleCount ? source[secondIndex] : 0
                                mixed += (first + second) * 0.5
                                channel += 1
                            }
                            target[outputFrame] = pcm16Sample(mixed / Float(channelCount))
                            outputFrame += 1
                        }
                    }
                }
                return output
            }
        }

        if asbd.mBitsPerChannel == 16 {
            let sampleCount = min(totalLength / MemoryLayout<Int16>.size, frameCount * channelCount)
            return raw.withMemoryRebound(to: Int16.self, capacity: sampleCount) { source in
                var output = Data(count: outputFrameCount * MemoryLayout<Int16>.size)
                output.withUnsafeMutableBytes { rawOutput in
                    guard let target = rawOutput.bindMemory(to: Int16.self).baseAddress else { return }
                    var outputFrame = 0
                    if isNonInterleaved {
                        while outputFrame < outputFrameCount {
                            let firstFrame = outputFrame * 2
                            let secondFrame = firstFrame + 1
                            var mixed = 0
                            var observedSamples = 0
                            var channel = 0
                            while channel < channelCount {
                                let channelBase = channel * frameCount
                                let firstIndex = channelBase + firstFrame
                                if firstIndex < sampleCount {
                                    mixed += Int(source[firstIndex])
                                    observedSamples += 1
                                }
                                let secondIndex = channelBase + secondFrame
                                if secondIndex < sampleCount {
                                    mixed += Int(source[secondIndex])
                                    observedSamples += 1
                                }
                                channel += 1
                            }
                            target[outputFrame] = observedSamples > 0
                                ? Int16(clamping: mixed / observedSamples)
                                : 0
                            outputFrame += 1
                        }
                    } else {
                        while outputFrame < outputFrameCount {
                            let firstBase = (outputFrame * 2) * channelCount
                            let secondBase = firstBase + channelCount
                            var mixed = 0
                            var observedSamples = 0
                            var channel = 0
                            while channel < channelCount {
                                let firstIndex = firstBase + channel
                                if firstIndex < sampleCount {
                                    mixed += Int(source[firstIndex])
                                    observedSamples += 1
                                }
                                let secondIndex = secondBase + channel
                                if secondIndex < sampleCount {
                                    mixed += Int(source[secondIndex])
                                    observedSamples += 1
                                }
                                channel += 1
                            }
                            target[outputFrame] = observedSamples > 0
                                ? Int16(clamping: mixed / observedSamples)
                                : 0
                            outputFrame += 1
                        }
                    }
                }
                return output
            }
        }

        return nil
    }

    private static func pcm16Sample(_ value: Float) -> Int16 {
        let clamped = min(max(value, -1), 1)
        return Int16(clamping: Int((clamped * 32_767).rounded()))
    }

    private static func floatingPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sampleBuffer.isValid,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let asbd = asbdPointer.pointee
        let channelCount = max(Int(asbd.mChannelsPerFrame), 1)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: asbd.mSampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return nil
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr,
              let raw = dataPointer,
              let channels = buffer.floatChannelData else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        if isFloat, asbd.mBitsPerChannel == 32 {
            let sampleCount = min(totalLength / MemoryLayout<Float>.size, frameCount * channelCount)
            raw.withMemoryRebound(to: Float.self, capacity: sampleCount) { source in
                copySamples(
                    source: source,
                    sampleCount: sampleCount,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    isNonInterleaved: isNonInterleaved,
                    into: channels
                )
            }
        } else if asbd.mBitsPerChannel == 16 {
            let sampleCount = min(totalLength / MemoryLayout<Int16>.size, frameCount * channelCount)
            raw.withMemoryRebound(to: Int16.self, capacity: sampleCount) { source in
                for frame in 0..<frameCount {
                    for channel in 0..<channelCount {
                        let index = sourceIndex(
                            frame: frame,
                            channel: channel,
                            frameCount: frameCount,
                            channelCount: channelCount,
                            isNonInterleaved: isNonInterleaved
                        )
                        channels[channel][frame] = index < sampleCount ? Float(source[index]) / 32768 : 0
                    }
                }
            }
        } else {
            return nil
        }

        return buffer
    }

    private static func copySamples(
        source: UnsafePointer<Float>,
        sampleCount: Int,
        frameCount: Int,
        channelCount: Int,
        isNonInterleaved: Bool,
        into channels: UnsafePointer<UnsafeMutablePointer<Float>>
    ) {
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let index = sourceIndex(
                    frame: frame,
                    channel: channel,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    isNonInterleaved: isNonInterleaved
                )
                channels[channel][frame] = index < sampleCount ? source[index] : 0
            }
        }
    }

    private static func sourceIndex(
        frame: Int,
        channel: Int,
        frameCount: Int,
        channelCount: Int,
        isNonInterleaved: Bool
    ) -> Int {
        if isNonInterleaved {
            return (channel * frameCount) + frame
        }
        return (frame * channelCount) + channel
    }
}

/// Single-shot input state for the AVAudioConverter callback. Mirrors
/// the legacy class's `ConverterInputState` so behaviour around the
/// "haveData → noDataNow" toggle is identical when the actor takes over
/// the production path.
private final class RealtimeConverterInputState: @unchecked Sendable {
    private let source: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didProvideInput = false

    init(source: AVAudioPCMBuffer) {
        self.source = source
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !didProvideInput else {
            status.pointee = .noDataNow
            return nil
        }
        didProvideInput = true
        status.pointee = .haveData
        return source
    }
}

// MARK: - Receive event parsing (Phase 3c)

/// Decoded shape of the events the realtime server emits. Subset of
/// what the legacy class consumes; the actor handles a small set of
/// types and falls through `default` on the rest.
struct RealtimeReceiveEvent: Decodable {
    let type: String
    let itemID: String?
    let previousItemID: String?
    let contentIndex: Int?
    let delta: String?
    let transcript: String?
    let error: RealtimeReceiveError?

    var transcriptItemKey: RealtimeTranscriptKey {
        .init(itemID: itemID, contentIndex: contentIndex)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case itemID = "item_id"
        case previousItemID = "previous_item_id"
        case contentIndex = "content_index"
        case delta
        case transcript
        case error
    }
}

struct RealtimeReceiveError: Decodable {
    let type: String?
    let code: String?
    let message: String?
}

/// Server-emitted application-level error event surfaced through the
/// realtime WebSocket as `{"type":"error", "error": {...}}`. The
/// receive loop wraps the message in this error type and routes it
/// through the same `scheduleReconnect` path used by transport
/// failures so the lifecycle exits `.live` (Codex Finding #8). Mirrors
/// the legacy class's `RealtimeServerEventError`.
struct RealtimeServerEventError: LocalizedError, Sendable {
    let message: String
    let serverType: String?
    let serverCode: String?
    var errorDescription: String? { message }
}

/// Synthetic error used by the audio-send escalation path. When
/// `socket.send(...)` throws, the actor treats that as a strong
/// signal the socket is dead and routes it through
/// `scheduleReconnect`. The wrapper preserves the underlying
/// description so retry logs / telemetry capture the original cause.
struct RealtimeSendFailureError: LocalizedError, Sendable {
    let underlying: String
    var errorDescription: String? { underlying }
}

/// One unique transcript item key in the upstream stream. Used as a
/// dictionary key for the actor's transcript timeline; an `item_id` +
/// `content_index` together uniquely identify a content slot.
struct RealtimeTranscriptKey: Hashable {
    private static let fallbackItemID = "__recappi_transcript_item"
    let itemID: String
    let contentIndex: Int

    init(itemID: String?, contentIndex: Int?) {
        self.itemID = itemID ?? Self.fallbackItemID
        self.contentIndex = contentIndex ?? 0
    }
}

/// Internal transcript item state. Mirrors the legacy class's
/// `TranscriptItem`. Marked `struct` since the actor mutates it through
/// the items dictionary.
struct RealtimeTranscriptItem {
    let text: String
    let isFinal: Bool
    let sequence: Int

    func appending(_ delta: String) -> RealtimeTranscriptItem {
        .init(text: text + delta, isFinal: false, sequence: sequence)
    }

    func replacingText(_ text: String, isFinal: Bool) -> RealtimeTranscriptItem {
        .init(text: text, isFinal: isFinal, sequence: sequence)
    }
}

/// Which stream a bilingual delta belongs to.
enum RealtimeBilingualStream {
    case source
    case translation
}

/// Continuous-stream segmenter for bilingual translation mode. Mirrors
/// the legacy class's `BilingualSegmentBuilder` minus the now-unused
/// boundary helpers (the active upstream block stays intact until the
/// session flushes — production smoke showed mid-stream splits cut
/// sentences in the wrong place).
final class RealtimeBilingualSegmentBuilder {
    private struct Pending {
        var sourceText: String = ""
        var translatedText: String = ""

        var hasContent: Bool {
            !sourceText.isEmpty || !translatedText.isEmpty
        }
    }

    private var finalized: [LiveCaptionSegment] = []
    private var pending = Pending()
    private var nextSequence = 0

    func append(stream: RealtimeBilingualStream, delta: String) {
        switch stream {
        case .source:
            pending.sourceText += delta
        case .translation:
            pending.translatedText += delta
        }
    }

    func finalizePending() {
        guard pending.hasContent else { return }
        let segment = LiveCaptionSegment(
            id: "bilingual-\(nextSequence)",
            sourceText: pending.sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
            translatedText: pending.translatedText.trimmingCharacters(in: .whitespacesAndNewlines),
            isFinal: true,
            sequence: nextSequence
        )
        finalized.append(segment)
        nextSequence += 1
        pending = Pending()
    }

    func snapshot() -> [LiveCaptionSegment] {
        var segments = finalized
        if !pending.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pending.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(
                LiveCaptionSegment(
                    id: "bilingual-\(nextSequence)",
                    sourceText: pending.sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
                    translatedText: pending.translatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                    isFinal: false,
                    sequence: nextSequence
                )
            )
        }
        return segments
    }
}

private extension Result where Success == Void, Failure: Error {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Character helpers for transcript / bilingual rendering

fileprivate extension Character {
    /// Sentence-ending punctuation recognized by the realtime display
    /// segmenter. ASCII + the CJK full-width counterparts so a Chinese
    /// sentence break on `。` triggers the same logic as `.` does for
    /// English.
    var isLiveCaptionSentenceEnding: Bool {
        [".", "!", "?", "。", "！", "？"].contains(self)
    }

    /// Rough CJK / Hangul / kana detector used by the segmenter to pick
    /// a tighter soft-cap when the transcript is in a CJK language.
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x3040...0x30FF).contains(scalar.value) ||
                (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}
