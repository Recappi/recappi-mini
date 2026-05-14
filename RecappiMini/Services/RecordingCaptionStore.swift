import Foundation

/// Phase 2 — caption persistence is being lifted out of
/// `BackendRealtimeLiveCaptionTranscriber.saveEntries` and into a
/// store owned by `AudioRecorder`. The store accumulates entries
/// across the restart-then-stop window so the legacy bug where a
/// stop arriving mid-restart silently dropped the outgoing
/// transcriber's caption history (Codex Finding #2) disappears.
///
/// The contract is intentionally small:
/// - `add(_:)` is the only mutator producers call — multiple
///   transcribers (outgoing + incoming during a restart) hand their
///   `[LiveCaptionEntry]` snapshots here and the store appends.
/// - `currentEntries()` is the read side; tests and the final
///   `stopRecording` flush use it.
/// - `flush(to:)` writes a single `live-captions.json` atomically.
///   The legacy `saveEntries` swallowed errors via `try?`; this one
///   throws so an unwritable session directory is surfaced rather
///   than silently dropping captions.
/// - `clear()` is the reset hook for `AudioRecorder.reset()`.
///
/// `@MainActor` because the only producer / consumer in production is
/// `AudioRecorder`, which is itself `@MainActor`. Keeping the store
/// pinned to the main actor avoids the per-call isolation hop that
/// would otherwise be needed for every `add(...)` from the restart /
/// stop paths.
@MainActor
final class RecordingCaptionStore {
    private var entries: [LiveCaptionEntry] = []

    /// Append a batch of entries. An empty batch is a no-op so the
    /// restart path can unconditionally forward whatever the outgoing
    /// transcriber returned without checking emptiness at every call
    /// site.
    func add(_ newEntries: [LiveCaptionEntry]) {
        guard !newEntries.isEmpty else { return }
        entries.append(contentsOf: newEntries)
    }

    /// Snapshot of accumulated entries in arrival order. Used by
    /// `stopRecording` to decide whether to bother touching the
    /// filesystem, and by tests to assert the carryover path actually
    /// preserved entries across a restart.
    func currentEntries() -> [LiveCaptionEntry] {
        entries
    }

    /// Atomically write the accumulated entries to
    /// `<sessionDir>/live-captions.json`. If the store is empty the
    /// method returns silently without producing a file — the legacy
    /// `saveEntries` had the same short-circuit and downstream
    /// consumers (transcript renderer, cloud uploader) treat a missing
    /// file as "no captions captured this recording".
    func flush(to sessionDir: URL) async throws {
        guard !entries.isEmpty else { return }
        let data = try JSONEncoder().encode(entries)
        let url = sessionDir.appendingPathComponent("live-captions.json")
        try data.write(to: url, options: .atomic)
    }

    /// Drop all accumulated entries. Used by `AudioRecorder.reset()`
    /// so a recycled recorder does not drag the previous recording's
    /// captions into the next session.
    func clear() {
        entries.removeAll()
    }
}
