import AppKit
import Foundation

enum CloudRecordingProcessingAction: String, CaseIterable, Identifiable, Sendable {
    case transcriptAndSummary

    var id: String { rawValue }
}

@MainActor
final class CloudLibraryStore: ObservableObject {
    enum LibraryState: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case signedOut
        case expired
        case failed(String)
    }

    @Published var state: LibraryState = .idle
    @Published var recordings: [CloudRecording] = []
    @Published var selectedRecordingID: String?
    @Published var totalRecordingCount: Int?
    @Published var transcriptCache: [String: TranscriptResponse] = [:]
    @Published var transcriptionJobsByRecordingID: [String: [TranscriptionJob]] = [:]
    @Published var speakerOverridesByRecordingID: [String: [String: CloudSpeakerDisplayOverride]] = [:]
    @Published var nextCursor: String?
    @Published var isLoadingMore = false
    @Published var isRefreshing = false
    @Published var isTranscriptLoading = false
    @Published var isJobHistoryLoading = false
    @Published var isDownloading = false
    @Published var isDeleting = false
    @Published var isSyncingToLocal = false
    @Published var isRetranscribing = false
    @Published var activeRecordingProcessingAction: CloudRecordingProcessingAction?
    @Published var processingPhasesByRecordingID: [String: ProcessingPhase] = [:]
    @Published var lastDownloadedAudioURL: URL?
    @Published var transcriptErrorMessage: String?
    @Published var billingStatus: BillingStatus?
    @Published var billingErrorMessage: String?
    @Published var isLoadingBilling = false
    @Published var isOpeningBilling = false
    @Published var localSessionURLsByRecordingID: [String: URL] = [:]
    // Count of local-only sessions on this machine that carry no account stamp
    // (legacy or recorded signed-out). Surfaced so the UI can offer an explicit
    // "claim these to the current account" action (#249).
    @Published var unattributedLocalSessionCount = 0
    @Published var liveCaptionTranscriptStatesByRecordingID: [String: LiveCaptionTranscriptLoadState] = [:]
    @Published var playbackAudioURLsByRecordingID: [String: URL] = [:]
    @Published var isPreparingPlaybackAudio = false
    @Published var playbackErrorMessage: String?
    @Published var lastSuccessfulRefreshAt: Date?
    @Published var isShowingCachedData = false
    @Published var cacheWarningMessage: String?
    @Published var hasNewerVersionForSelection: Bool = false
    @Published var recordingIDsWithNewerVersions: Set<String> = []
    /// Snapshot of `recording.updatedAt` taken at the moment a transcript
    /// was written into `transcriptCache`. The freshness check used to read
    /// `recordings[id].updatedAt` directly, but that array is refreshed by
    /// `listRecordings()` independently of the transcript cache, so by the
    /// time we tried to detect "summary landed after cache" the cached
    /// recording metadata had already been overwritten with the latest
    /// timestamp and the diff was always zero. Capturing the snapshot at
    /// cache-write-time is the actual freshness anchor for transcripts.
    @Published var transcriptCacheRecordingUpdatedAt: [String: Date] = [:]

    let config: AppConfig
    let sessionStore: AuthSessionStore
    let cache: CloudLibraryCache
    let pageLimit: Int
    var isRemoteRefreshInFlight = false
    var transcriptLoadingRecordingIDs: Set<String> = []
    var jobHistoryLoadingRecordingIDs: Set<String> = []
    var selectionDetailRefreshTask: Task<Void, Never>?
    var cachePersistTask: Task<Void, Never>?
    /// In-memory once-per-session guard so the shape-based fallback (cached
    /// transcript present but summary missing) does not retry the network
    /// on every selection switch when the recording genuinely has no
    /// summary yet. Persisted equivalents can live in the SQLite migration.
    var summaryRefreshAttemptedRecordingIDs: Set<String> = []
    /// Recording ids created/updated by this app's recording pipeline during
    /// the current process, with the time they were last touched locally.
    /// The primary freshness fix is to fetch server detail immediately after
    /// processing completes; this is only a short-lived fallback for late
    /// server-side summarization updates that land shortly after that fetch.
    var locallyManagedRecordingUpdatedAt: [String: Date] = [:]

    init(
        config: AppConfig = .shared,
        sessionStore: AuthSessionStore = .shared,
        cache: CloudLibraryCache = .shared,
        pageLimit: Int = 20
    ) {
        self.config = config
        self.sessionStore = sessionStore
        self.cache = cache
        self.pageLimit = pageLimit
    }

    var selectedRecording: CloudRecording? {
        guard let selectedRecordingID else { return nil }
        return recordings.first(where: { $0.id == selectedRecordingID })
    }

    var selectedTranscript: TranscriptResponse? {
        guard let selectedRecordingID else { return nil }
        return transcriptCache[selectedRecordingID]
    }

    var isSelectedTranscriptLoading: Bool {
        guard let selectedRecordingID else { return false }
        return transcriptLoadingRecordingIDs.contains(selectedRecordingID)
    }

    var selectedTranscriptionJobs: [TranscriptionJob] {
        guard let selectedRecordingID else { return [] }
        return transcriptionJobsByRecordingID[selectedRecordingID] ?? []
    }

    var isSelectedJobHistoryLoading: Bool {
        guard let selectedRecordingID else { return false }
        return jobHistoryLoadingRecordingIDs.contains(selectedRecordingID)
    }

    var selectedLatestTranscriptionJob: TranscriptionJob? {
        selectedTranscriptionJobs.first
    }

    var selectedProcessingPhase: ProcessingPhase? {
        guard let selectedRecordingID else { return nil }
        return processingPhasesByRecordingID[selectedRecordingID]
    }

    var selectedActiveJobPollingKey: String {
        var parts = selectedTranscriptionJobs
            .filter { $0.status.isActive }
            .map(\.id)
        if let selectedRecordingID,
           let recording = selectedRecording,
           let transcript = selectedTranscript,
           Self.shouldPollSummary(
               cachedTranscript: transcript,
               recordingStatus: recording.status
           ) {
            let status = transcript.summaryStatus?.rawValue ?? "unknown"
            parts.append("summary:\(selectedRecordingID):\(transcript.id):\(status)")
        }
        return parts.joined(separator: ",")
    }

    var selectedLocalSessionURL: URL? {
        guard let selectedRecordingID else { return nil }
        return localSessionURLsByRecordingID[selectedRecordingID]
    }

    var selectedLiveCaptionTranscriptState: LiveCaptionTranscriptLoadState {
        guard let selectedRecordingID else { return .unavailable }
        return liveCaptionTranscriptStatesByRecordingID[selectedRecordingID] ?? .unavailable
    }

    var selectedPlaybackAudioURL: URL? {
        guard let recording = selectedRecording else { return nil }
        return localRecordingAudioURL(for: recording) ?? playbackAudioURLsByRecordingID[recording.id]
    }

    var selectedPlaybackSourceDescription: String {
        guard let recording = selectedRecording else { return "No recording selected" }
        if localRecordingAudioURL(for: recording) != nil {
            return "Using local audio"
        }
        if playbackAudioURLsByRecordingID[recording.id] != nil {
            return "Using cached cloud audio"
        }
        return "Cloud audio preview"
    }

    var hasMorePages: Bool {
        nextCursor?.isEmpty == false
    }

}
