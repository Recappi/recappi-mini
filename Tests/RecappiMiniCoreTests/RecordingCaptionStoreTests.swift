import XCTest
@testable import RecappiMini

/// Phase 2 — caption persistence is being lifted out of
/// `BackendRealtimeLiveCaptionTranscriber.saveEntries` and into a new
/// `RecordingCaptionStore` owned by `AudioRecorder`. Each transcriber
/// returns its `[LiveCaptionEntry]` on stop; the store accumulates
/// them across the restart-then-stop window so the legacy "caption
/// loss during restart-then-stop" race (Codex Finding #2) disappears.
///
/// Tests written failing-first. See repo CLAUDE.md.
@MainActor
final class RecordingCaptionStoreTests: XCTestCase {
    private var tmpRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("recappi-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tmpRoot {
            try? FileManager.default.removeItem(at: tmpRoot)
        }
        tmpRoot = nil
        try await super.tearDown()
    }

    // MARK: - currentEntries

    /// A fresh store has no entries. The `currentEntries()` API is
    /// load-bearing for `AudioRecorder.stopRecording` to make a final
    /// "anything to flush?" decision before touching the filesystem.
    func testFreshStoreHasNoEntries() {
        let store = RecordingCaptionStore()
        XCTAssertEqual(store.currentEntries(), [])
    }

    // MARK: - add + currentEntries

    /// Adding a batch of entries makes them available through
    /// `currentEntries()` in order. The store is append-only and does
    /// not re-order or de-rank what callers hand it.
    func testAddAccumulatesEntriesInOrder() {
        let store = RecordingCaptionStore()
        let first = [
            LiveCaptionEntry(text: "alpha", isFinal: true, startedAtMs: 0, endedAtMs: 100),
            LiveCaptionEntry(text: "beta", isFinal: true, startedAtMs: 100, endedAtMs: 200),
        ]
        let second = [
            LiveCaptionEntry(text: "gamma", isFinal: true, startedAtMs: 200, endedAtMs: 300),
        ]
        store.add(first)
        store.add(second)
        XCTAssertEqual(store.currentEntries(), first + second)
    }

    /// Calling `add([])` with an empty batch is a no-op — important so
    /// the restart path can unconditionally hand the store whatever the
    /// outgoing transcriber returned (which is often empty for a
    /// just-started session).
    func testAddEmptyBatchIsNoOp() {
        let store = RecordingCaptionStore()
        store.add([])
        XCTAssertEqual(store.currentEntries(), [])
        let one = [LiveCaptionEntry(text: "x", isFinal: true, startedAtMs: nil, endedAtMs: nil)]
        store.add(one)
        store.add([])
        XCTAssertEqual(store.currentEntries(), one)
    }

    // MARK: - flush

    /// `flush` writes `currentEntries()` as JSON to `live-captions.json`
    /// inside the supplied session directory. The on-disk format must
    /// match what the legacy `saveEntries` wrote, otherwise downstream
    /// consumers (transcript renderer, cloud uploader) silently break.
    func testFlushRoundTripsEntriesToLiveCaptionsJSON() async throws {
        let store = RecordingCaptionStore()
        let entries = [
            LiveCaptionEntry(text: "round-trip", isFinal: true, startedAtMs: 0, endedAtMs: 50),
            LiveCaptionEntry(text: "second line", isFinal: true, startedAtMs: 50, endedAtMs: 100),
        ]
        store.add(entries)

        try await store.flush(to: tmpRoot)

        let url = tmpRoot.appendingPathComponent("live-captions.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "flush must write live-captions.json")

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([LiveCaptionEntry].self, from: data)
        XCTAssertEqual(decoded, entries)
    }

    /// `flush` on an empty store must NOT produce `live-captions.json`.
    /// The legacy `saveEntries` short-circuited on empty input and we
    /// preserve that behavior so callers don't have to special-case
    /// "no captions captured this recording".
    func testFlushEmptyStoreDoesNotCreateFile() async throws {
        let store = RecordingCaptionStore()
        try await store.flush(to: tmpRoot)
        let url = tmpRoot.appendingPathComponent("live-captions.json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "flush on empty store must not create live-captions.json"
        )
    }

    /// Two flushes overwrite atomically — calling flush a second time
    /// after appending more entries replaces the file with the combined
    /// accumulator content. This pins the "stopRecording flushes once
    /// at the end" contract.
    func testFlushIsIdempotentAndIncludesNewlyAddedEntries() async throws {
        let store = RecordingCaptionStore()
        store.add([LiveCaptionEntry(text: "one", isFinal: true, startedAtMs: nil, endedAtMs: nil)])
        try await store.flush(to: tmpRoot)

        store.add([LiveCaptionEntry(text: "two", isFinal: true, startedAtMs: nil, endedAtMs: nil)])
        try await store.flush(to: tmpRoot)

        let url = tmpRoot.appendingPathComponent("live-captions.json")
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([LiveCaptionEntry].self, from: data)
        XCTAssertEqual(
            decoded.map(\.text),
            ["one", "two"],
            "Second flush must include entries accumulated since the first flush."
        )
    }

    // MARK: - clear

    /// `clear` resets the accumulator; subsequent `currentEntries()`
    /// returns empty. Used by `AudioRecorder.reset()` so a recycled
    /// recorder doesn't drag previous-recording captions forward into
    /// the next session.
    func testClearResetsTheAccumulator() {
        let store = RecordingCaptionStore()
        store.add([LiveCaptionEntry(text: "stale", isFinal: true, startedAtMs: nil, endedAtMs: nil)])
        XCTAssertFalse(store.currentEntries().isEmpty)

        store.clear()
        XCTAssertEqual(store.currentEntries(), [], "clear must drop all accumulated entries.")
    }

    // MARK: - failure mode

    /// Flush to a path whose parent directory does not exist must throw,
    /// so callers (e.g., `AudioRecorder.stopRecording`) can decide how
    /// to surface a persistence failure rather than silently losing
    /// captions. The legacy `saveEntries` swallowed all write errors
    /// via `try?` — this is an explicit improvement.
    func testFlushToNonExistentDirectoryThrows() async {
        let store = RecordingCaptionStore()
        store.add([LiveCaptionEntry(text: "x", isFinal: true, startedAtMs: nil, endedAtMs: nil)])

        let badRoot = tmpRoot.appendingPathComponent("does-not-exist")
        do {
            try await store.flush(to: badRoot)
            XCTFail("flush to a missing directory must throw")
        } catch {
            // Expected — any throw is fine for this contract.
        }
    }
}
