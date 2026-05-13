import XCTest
@testable import RecappiMini

/// F5 — rapid successive `restartLiveCaptions(...)` invocations must
/// only result in one final live-caption provider. Today's
/// implementation races: the second restart captures `oldTranscriber =
/// nil` (the first restart already cleared the field) and skips the
/// close-await, so its `startLiveCaptionProvider` runs *before* the
/// first restart's spawned Task finishes awaiting the slow close.
/// When the first Task finally resumes, it calls its own
/// `startLiveCaptionProvider` and stomps the newer provider that the
/// second restart had already installed — re-producing the
/// near-simultaneous `POST /sessions` symptom this work has been
/// chasing.
///
/// The fix is a generation-token guard: each restart bumps a counter
/// and remembers its own value; the Task only proceeds past the
/// `stop` await if the generation hasn't moved since it was spawned.
@MainActor
final class AudioRecorderRestartLiveCaptionsTests: XCTestCase {
    /// Two restarts in quick succession: the first restart's `stop`
    /// callback is held for 80 ms (simulating the bounded close-await
    /// in `BackendRealtimeLiveCaptionTranscriber.stop`). The second
    /// restart fires while the first is still awaiting. Expectation:
    /// only the SECOND restart's `start` callback runs to completion.
    func testRapidSuccessiveRestartsResultInSingleProvider() async {
        let recorder = AudioRecorder()
        let stops = StopRecorder()
        let starts = StartRecorder()

        recorder.installLiveCaptionRestartHooksForTesting(
            stop: { _ in
                // Slow stop — first restart's await keeps the Task
                // suspended past the moment the second restart begins.
                try? await Task.sleep(nanoseconds: 80_000_000)
                stops.recordStop()
            },
            start: { localeID in
                starts.recordStart(localeID)
            }
        )

        recorder.restartLiveCaptionsForTesting(localeIdentifier: "en-A")
        recorder.restartLiveCaptionsForTesting(localeIdentifier: "en-B")

        // Allow both spawned Tasks to settle. 250 ms is comfortably
        // longer than two consecutive 80 ms stops, so a buggy
        // implementation has time to fire both starts before we
        // assert.
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(
            starts.localeIdentifiers, ["en-B"],
            "Only the SECOND restart's start callback must run — got: \(starts.localeIdentifiers)"
        )
    }

    /// Bug #3: serial-restart contract must hold even when the SECOND
    /// restart captures a nil `oldTranscriber` (because the first
    /// restart already cleared `liveCaptionTranscriber`). Production
    /// `stopLiveCaptionsAwaitingClose(nil, ...)` returns instantly via
    /// its `guard transcriber != nil else { return }`, so the second
    /// restart's `start` would race ahead and fire its claim POST
    /// while the first restart's stop is still in flight on the
    /// real socket — producing the "two concurrent /sessions claims
    /// for the same userKey" symptom seen in production.
    ///
    /// The fix is to serialize the restart Tasks themselves so the
    /// second restart's body cannot begin until the first restart's
    /// body (including its stop-await) has fully returned.
    func testSecondRestartWaitsForFirstRestartStopEvenWhenSecondCapturesNilTranscriber() async {
        let recorder = AudioRecorder()
        let events = EventRecorder()

        // Pre-seed a sentinel transcriber so the FIRST restart captures
        // it (non-nil), and the SECOND restart (running on the
        // MainActor immediately after) captures nil — the buggy path.
        final class Sentinel {}
        recorder.setLiveCaptionTranscriberForTesting(Sentinel())

        recorder.installLiveCaptionRestartHooksForTesting(
            stop: { [events] oldTranscriber in
                // Production semantics: a nil transcriber means there's
                // nothing to stop — return instantly. A non-nil
                // transcriber simulates the real bounded close-await.
                guard oldTranscriber != nil else { return }
                events.record("A.stop.begin")
                try? await Task.sleep(nanoseconds: 80_000_000)
                events.record("A.stop.end")
            },
            start: { [events] localeID in
                events.record("start:\(localeID)")
            }
        )

        recorder.restartLiveCaptionsForTesting(localeIdentifier: "en-A")
        recorder.restartLiveCaptionsForTesting(localeIdentifier: "en-B")

        // Allow both spawned Tasks to settle, with comfortable margin
        // over the 80 ms slow stop.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let recorded = events.snapshot()

        // The serial-restart contract: the second restart's `start`
        // must NOT begin until the first restart's `stop` has
        // completed. With the bug, "start:en-B" appears BEFORE
        // "A.stop.end" because Task2 sees nil and skips the await.
        guard let stopEndIdx = recorded.firstIndex(of: "A.stop.end") else {
            XCTFail("Expected first restart's stop to complete; events: \(recorded)")
            return
        }
        guard let secondStartIdx = recorded.firstIndex(of: "start:en-B") else {
            XCTFail("Expected second restart's start to fire; events: \(recorded)")
            return
        }
        XCTAssertLessThan(
            stopEndIdx,
            secondStartIdx,
            "Second restart's start must not run until first restart's stop completes; events: \(recorded)"
        )
    }

    /// Focused unit-test on the generation guard itself. Bump the
    /// generation between spawning the Task and resolving its `stop`
    /// — the Task must observe the bump and decline to call `start`.
    func testRestartGenerationGuardSupersedesStaleProvider() async {
        let recorder = AudioRecorder()
        let starts = StartRecorder()
        let stopReleased = AsyncOneShot()

        recorder.installLiveCaptionRestartHooksForTesting(
            stop: { _ in
                await stopReleased.wait()
            },
            start: { localeID in
                starts.recordStart(localeID)
            }
        )

        recorder.restartLiveCaptionsForTesting(localeIdentifier: "stale")

        // Move the generation forward while restart#1's Task is still
        // suspended in `await stop(...)`. This simulates restart#2
        // happening on the MainActor before restart#1 resumes.
        recorder.bumpRestartGenerationForTesting()

        // Release the slow stop. The Task should now resume, check
        // the generation, observe the bump, and refuse to start.
        stopReleased.fire()

        // Drain.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(
            starts.localeIdentifiers.isEmpty,
            "Generation guard must suppress the stale Task's start; got: \(starts.localeIdentifiers)"
        )
    }
}

// MARK: - Helpers

private final class StopRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func recordStop() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    var stopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

private final class StartRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [String] = []

    func recordStart(_ localeIdentifier: String) {
        lock.lock(); defer { lock.unlock() }
        captured.append(localeIdentifier)
    }

    var localeIdentifiers: [String] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }
}

/// Append-only thread-safe event log. Used to assert the relative
/// order of `stop`/`start` callbacks across rapid successive
/// restart invocations.
private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

/// Minimal async one-shot signal — `wait()` suspends until `fire()`
/// is invoked exactly once. Used to keep the test's stub `stop`
/// callback suspended deterministically.
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
