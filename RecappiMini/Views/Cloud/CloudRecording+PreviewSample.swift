#if DEBUG
import Foundation

extension CloudRecording {
    /// Convenience factory for SwiftUI Previews. Builds a fully-populated
    /// `CloudRecording` with a Chrome / Google Meet "source app" so the
    /// row icon resolves to a real bundle on the dev machine when present.
    static func previewSample(
        id: String,
        title: String,
        status: CloudRecordingStatus = .ready,
        createdAt: Date = Date(),
        durationMs: Int = 60_000
    ) -> CloudRecording {
        CloudRecording(
            id: id,
            userId: "preview-user",
            title: title,
            summaryTitle: title,
            sourceTitle: "Google Meet",
            sourceAppName: "Google Chrome",
            sourceAppBundleID: "com.google.Chrome",
            r2Key: nil,
            r2UploadId: nil,
            status: status,
            sizeBytes: 1_000_000,
            durationMs: durationMs,
            sampleRate: 48_000,
            channels: 2,
            contentType: "audio/mpeg",
            activeTranscriptId: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}

@MainActor
extension CloudLibraryStore {
    /// Spins up a `CloudLibraryStore` already populated and in the `.loaded`
    /// state so previews render the steady-state UI instead of the loading
    /// spinner. No network calls fire.
    static func previewLoaded(recordings: [CloudRecording]) -> CloudLibraryStore {
        let store = CloudLibraryStore()
        store.recordings = recordings
        store.selectedRecordingID = recordings.first?.id
        store.state = recordings.isEmpty ? .empty : .loaded
        store.lastSuccessfulRefreshAt = Date()
        store.totalRecordingCount = recordings.count
        return store
    }
}
#endif
