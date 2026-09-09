import XCTest
@testable import RecappiMini

/// Regression tests for the leading-edge in-flight guard in
/// `CloudLibraryStore.loadJobHistoryForSelection(requiresFreshFetch:)`.
///
/// The guard coalesces simultaneous UI triggers into a single
/// `GET /api/recordings/:id/jobs`, which makes that request *shared*: the
/// callers it drops have no request of their own left to fall back on. The
/// owner is therefore issued from an **unstructured** task, so cancelling the
/// view Task that happened to win the claim — a torn-down detail view, or
/// `scheduleSelectedDetailRefresh` cancelling and replacing
/// `selectionDetailRefreshTask` — cannot abandon the callers it coalesced.
///
/// There is no seam for stubbing the client `runAuthorized` builds
/// (`RecappiAPIClient` is constructed inline over the shared
/// `RecappiNetworking.bearerSession`), so these tests do not observe the HTTP
/// response. They drive the real production method in a signed-out process,
/// where the request fails fast inside `ensureAuthorized`, and assert the
/// *ownership* contract around it:
///
///  - the owner stays in flight across an `await` (it would not, if the
///    request were issued inline — the signed-out failure never suspends),
///  - the request body still runs and applies its outcome after the owner's
///    Task is cancelled,
///  - the claim is released exactly once, and
///  - a `requiresFreshFetch` reload queued by a dropped caller is drained
///    rather than stranded.
final class CloudLibraryStoreJobHistoryCoalescingTests: XCTestCase {
    private static let recordingID = "rec_job_history_coalescing"

    /// A remote (not local-only) recording, so `loadJobHistoryForSelection`
    /// reaches the in-flight guard instead of the local short-circuit.
    @MainActor
    private func makeStore() -> (CloudLibraryStore, CloudRecording) {
        let recording = CloudRecording(
            id: Self.recordingID,
            userId: "user_123",
            title: "Weekly sync",
            summaryTitle: nil,
            sourceTitle: nil,
            sourceAppName: nil,
            sourceAppBundleID: nil,
            r2Key: "recordings/user_123/\(Self.recordingID).m4a",
            r2UploadId: nil,
            status: .ready,
            sizeBytes: 1_024,
            durationMs: 60_000,
            sampleRate: nil,
            channels: nil,
            contentType: "audio/aac",
            activeTranscriptId: nil,
            createdAt: nil,
            updatedAt: nil
        )
        let store = CloudLibraryStore()
        store.recordings = [recording]
        // Assign directly: `select(_:)` also schedules a cache persist and a
        // detail refresh, and the latter calls back into
        // `loadJobHistoryForSelection(requiresFreshFetch: true)`.
        store.selectedRecordingID = recording.id
        return (store, recording)
    }

    /// The owner claims synchronously and then suspends on the unstructured
    /// request task, so one yield is enough; the bound is only a safety net.
    @MainActor
    private func waitUntilJobHistoryClaimed(_ store: CloudLibraryStore) async {
        for _ in 0..<200 {
            if store.jobHistoryLoadingRecordingIDs.contains(Self.recordingID) { return }
            await Task.yield()
        }
    }

    /// A persisted debug token would send `ensureAuthorized` to the real
    /// backend, which is neither hermetic nor fast. Skip rather than do I/O.
    @MainActor
    private func skipIfSignedIn() throws {
        try XCTSkipIf(
            AuthSessionStore.shared.bearerToken() != nil,
            "Requires a signed-out process: a persisted token makes loadJobHistoryForSelection hit the network."
        )
    }

    @MainActor
    func testCancelledJobHistoryOwnerStillServesPlainCoalescedCaller() async throws {
        try skipIfSignedIn()
        let (store, recording) = makeStore()

        let owner = Task { await store.loadJobHistoryForSelection() }
        await waitUntilJobHistoryClaimed(store)
        XCTAssertTrue(
            store.jobHistoryLoadingRecordingIDs.contains(recording.id),
            "The owner must still hold the claim across its await — the request is issued from an unstructured task, not inline."
        )

        // The view that happened to win the claim is torn down mid-flight.
        owner.cancel()

        // A plain UI trigger for the same recording is coalesced onto the
        // owner's request and leaves no trace of its own.
        await store.loadJobHistoryForSelection()
        XCTAssertTrue(
            store.jobHistoryReloadRequestedRecordingIDs.isEmpty,
            "A plain caller must not queue a reload; it rides the in-flight request."
        )

        await owner.value

        // The cancelled owner still carried the shared request to completion
        // and applied its outcome to state keyed by recording id, so the
        // caller it dropped is served rather than stranded.
        XCTAssertNotNil(
            store.cacheWarningMessage,
            "The shared request must still run and apply its outcome after the owner's Task is cancelled."
        )
        XCTAssertFalse(
            store.jobHistoryLoadingRecordingIDs.contains(recording.id),
            "The claim must be released on every path, including a cancelled owner."
        )
        XCTAssertTrue(
            store.jobHistoryReloadRequestedRecordingIDs.isEmpty,
            "Nothing was queued, so nothing may be left behind."
        )
    }

    @MainActor
    func testCancelledJobHistoryOwnerStillServesFreshFetchCaller() async throws {
        try skipIfSignedIn()
        let (store, recording) = makeStore()

        let owner = Task { await store.loadJobHistoryForSelection() }
        await waitUntilJobHistoryClaimed(store)
        XCTAssertTrue(
            store.jobHistoryLoadingRecordingIDs.contains(recording.id),
            "The owner must still hold the claim across its await — the request is issued from an unstructured task, not inline."
        )

        owner.cancel()

        // A caller that invalidated state before calling is dropped by the
        // guard, so it queues a reload the owner must honour.
        await store.loadJobHistoryForSelection(requiresFreshFetch: true)
        XCTAssertTrue(
            store.jobHistoryReloadRequestedRecordingIDs.contains(recording.id),
            "A requiresFreshFetch caller dropped by the guard must queue a reload."
        )

        await owner.value

        XCTAssertFalse(
            store.jobHistoryReloadRequestedRecordingIDs.contains(recording.id),
            "A cancelled owner must still drain the queued reload. Leaving the flag set strands that caller: `.task(id:)` will not refire while the recording id is unchanged, and every other caller needs a fresh user action."
        )
        XCTAssertFalse(
            store.jobHistoryLoadingRecordingIDs.contains(recording.id),
            "The claim must be released on every path, including the trailing-edge re-fetch."
        )
    }
}
