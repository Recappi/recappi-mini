import XCTest
@testable import RecappiMini

/// Phase 2 — Codex Finding #2 ("caption loss during restart-then-
/// stop") pins. Before Phase 2 the live-caption transcriber lived in
/// a plain optional field on `AudioRecorder`; while a
/// `restartLiveCaptions(...)` Task was suspended in its stop-await,
/// `liveCaptionTranscriber` was already `nil`, and a `stopRecording`
/// arriving in that window saw nothing to drain. The old transcriber's
/// accumulated entries plus whatever the in-flight new transcriber had
/// collected were silently dropped.
///
/// The fix: introduce an explicit `LiveCaptionState` enum on
/// `AudioRecorder` whose `.transitioning(from:to:transitionTask:_)`
/// case is observable to `stopRecording`, and route caption
/// persistence through a `RecordingCaptionStore`. `restartLive-
/// Captions(...)` snapshots the outgoing transcriber's entries
/// synchronously into the store before awaiting the close handshake;
/// `stopRecording` snapshots the active (or transitioning-to)
/// transcriber's entries and flushes everything once.
@MainActor
final class AudioRecorderLiveCaptionStateTests: XCTestCase {
    // MARK: - Stop during a restart's stop-await must not lose old captions

    /// The headline Codex Finding #2 regression test. A restart is in
    /// flight (stop-await suspended); a stop arrives in that window.
    /// Pre-Phase 2: `liveCaptionTranscriber` had already been set to
    /// nil by `restartLiveCaptions`, so `stopRecording`'s drain saw
    /// nothing and silently lost the old transcriber's accumulated
    /// captions. Post-Phase 2: `restartLiveCaptions` snapshots the
    /// outgoing transcriber's entries into `RecordingCaptionStore`
    /// synchronously BEFORE entering `.transitioning`, so the store
    /// retains them even if a `stopRecording` cancels the transition
    /// task and finalizes immediately.
    ///
    /// Stop-then-start order is preserved (no concurrent `/sessions`
    /// claim POSTs), so `to` is nil during the close-handshake
    /// window — the new transcriber is constructed only after
    /// `stopOverride` returns. This test pins exactly the old-
    /// transcriber's captions, which is what gets dropped before
    /// the fix.
    func testStopDuringRestartPreservesOldTranscriberCaptions() async throws {
        let recorder = AudioRecorder()
        let tmp = try makeTempSessionDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let stopGate = AsyncOneShot()
        let oldEntries = [
            LiveCaptionEntry(text: "from-old-A", isFinal: true, startedAtMs: 0, endedAtMs: 50),
            LiveCaptionEntry(text: "from-old-B", isFinal: true, startedAtMs: 50, endedAtMs: 100),
        ]
        let stub = StubLiveCaptionLifecycleHooks()
        stub.drainEntries = { provider in
            // Map sentinel identity → entries. The "old" sentinel is
            // installed via `installRunningLiveCaptionTranscriber-
            // ForTesting`; any other sentinel produces no entries.
            guard case .testSentinel(let object) = provider,
                  let sentinel = object as? IdentifiableSentinel else {
                return []
            }
            return sentinel.tag == "old" ? oldEntries : []
        }
        stub.stop = { [stopGate] _ in
            await stopGate.wait()
        }
        stub.start = { [weak recorder] _ in
            // Production-equivalent: `startLiveCaptionProvider` would
            // construct the new transcriber here, transitioning the
            // state to `.running`. In the test path we simulate it by
            // installing a fresh sentinel so subsequent stop-finalize
            // observes a `.running` state.
            recorder?.installRunningLiveCaptionTranscriberForTesting(IdentifiableSentinel(tag: "new"))
        }
        recorder.installPhase2LiveCaptionHooksForTesting(stub)

        // Seed the "old" transcriber as `.running`; `restartLive-
        // Captions` will snapshot it before awaiting the (slow)
        // close handshake.
        recorder.installRunningLiveCaptionTranscriberForTesting(IdentifiableSentinel(tag: "old"))

        // Kick off a restart whose stop-await stays suspended.
        recorder.restartLiveCaptionsForTesting(localeIdentifier: "en-new")

        // Allow the restart Task to dispatch and reach the stop-await.
        await Task.yield()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Drive the stop-finalize path while the transition is still
        // in flight (state is `.transitioning(from: oldSentinel, to:
        // nil, ...)` at this point).
        async let finalize: Void = recorder.finalizeLiveCaptionsForStopTesting(saveTo: tmp)
        try? await Task.sleep(nanoseconds: 10_000_000)
        // Release the slow stop so the restart Task can resolve.
        stopGate.fire()
        await finalize

        let captured = try loadCaptionsFile(at: tmp)
        XCTAssertEqual(
            captured.map(\.text), ["from-old-A", "from-old-B"],
            "Stop arriving mid-restart must preserve the old transcriber's captions."
        )
    }

    // MARK: - Stop with no captions at all

    /// Stop on an idle recorder (no transcriber ever active) is a
    /// graceful no-op: the store stays empty and no
    /// `live-captions.json` is produced — same as the pre-Phase 2
    /// short-circuit in the legacy `saveEntries`.
    func testStopWithNoActiveCaptionsIsNoOp() async throws {
        let recorder = AudioRecorder()
        let tmp = try makeTempSessionDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let stub = StubLiveCaptionLifecycleHooks()
        stub.drainEntries = { _ in [] }
        stub.stop = { _ in }
        stub.start = { _ in }
        recorder.installPhase2LiveCaptionHooksForTesting(stub)

        // No transcriber sentinel, no restart — live-caption state is
        // `.none`.
        await recorder.finalizeLiveCaptionsForStopTesting(saveTo: tmp)

        let url = tmp.appendingPathComponent("live-captions.json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "Stop with no captions must NOT create live-captions.json"
        )
    }

    // MARK: - Stop on .running drains the active transcriber

    /// The happy path. There's no in-flight restart; the active
    /// transcriber's entries must end up in `live-captions.json`.
    func testStopOnRunningStateDrainsActiveTranscriber() async throws {
        let recorder = AudioRecorder()
        let tmp = try makeTempSessionDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let activeEntries = [
            LiveCaptionEntry(text: "running-1", isFinal: true, startedAtMs: 0, endedAtMs: 25),
            LiveCaptionEntry(text: "running-2", isFinal: true, startedAtMs: 25, endedAtMs: 50),
        ]
        let stub = StubLiveCaptionLifecycleHooks()
        stub.drainEntries = { provider in
            guard case .testSentinel(let object) = provider,
                  let sentinel = object as? IdentifiableSentinel else {
                return []
            }
            return sentinel.tag == "active" ? activeEntries : []
        }
        stub.stop = { _ in }
        stub.start = { _ in }
        recorder.installPhase2LiveCaptionHooksForTesting(stub)

        recorder.installRunningLiveCaptionTranscriberForTesting(IdentifiableSentinel(tag: "active"))

        await recorder.finalizeLiveCaptionsForStopTesting(saveTo: tmp)

        let captured = try loadCaptionsFile(at: tmp)
        XCTAssertEqual(captured.map(\.text), ["running-1", "running-2"])
    }

    // MARK: - Helpers

    private func makeTempSessionDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recappi-stop-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadCaptionsFile(at sessionDir: URL) throws -> [LiveCaptionEntry] {
        let url = sessionDir.appendingPathComponent("live-captions.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([LiveCaptionEntry].self, from: data)
    }
}

// MARK: - Test fixtures

/// Tag-bearing sentinel so the stub `drainEntries` hook can map a
/// specific transcriber identity to a scripted set of entries.
final class IdentifiableSentinel: @unchecked Sendable {
    let tag: String
    init(tag: String) {
        self.tag = tag
    }
}

/// One-shot async signal used to gate the simulated slow-close in the
/// stop hook. `wait()` suspends until `fire()` is invoked once.
private final class AsyncOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
                return
            }
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func fire() {
        lock.lock()
        guard !fired else { lock.unlock(); return }
        fired = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }
}
