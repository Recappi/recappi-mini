import AppKit
import Foundation

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

    @Published private(set) var state: LibraryState = .idle
    @Published private(set) var recordings: [CloudRecording] = []
    @Published private(set) var selectedRecordingID: String?
    @Published private(set) var transcriptCache: [String: TranscriptResponse] = [:]
    @Published private(set) var nextCursor: String?
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isTranscriptLoading = false
    @Published private(set) var isDownloading = false
    @Published private(set) var isDeleting = false
    @Published private(set) var isSyncingToLocal = false
    @Published private(set) var lastDownloadedAudioURL: URL?
    @Published private(set) var transcriptErrorMessage: String?
    @Published private(set) var billingStatus: BillingStatus?
    @Published private(set) var billingErrorMessage: String?
    @Published private(set) var isLoadingBilling = false
    @Published private(set) var isOpeningBilling = false
    @Published private(set) var localSessionURLsByRecordingID: [String: URL] = [:]
    @Published private(set) var playbackAudioURLsByRecordingID: [String: URL] = [:]
    @Published private(set) var isPreparingPlaybackAudio = false
    @Published private(set) var playbackErrorMessage: String?

    private let config: AppConfig
    private let sessionStore: AuthSessionStore
    private let pageLimit: Int

    init(
        config: AppConfig = .shared,
        sessionStore: AuthSessionStore = .shared,
        pageLimit: Int = 20
    ) {
        self.config = config
        self.sessionStore = sessionStore
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

    var selectedLocalSessionURL: URL? {
        guard let selectedRecordingID else { return nil }
        return localSessionURLsByRecordingID[selectedRecordingID]
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

    func loadInitialIfNeeded() async {
        guard recordings.isEmpty else { return }
        await refresh()
    }

    func refresh() async {
        guard await prepareForAuthenticatedRequest() else { return }
        isRefreshing = !recordings.isEmpty
        state = recordings.isEmpty ? .loading : .loaded
        await refreshBillingStatus()

        do {
            let page = try await runAuthorized { client in
                try await client.listRecordings(limit: pageLimit)
            }
            recordings = page.items
            nextCursor = page.nextCursor
            selectDefaultRecordingIfNeeded()
            await refreshLocalSessionLinks()
            state = recordings.isEmpty ? .empty : .loaded
        } catch {
            apply(error: error)
        }

        isRefreshing = false
    }

    func refreshBillingStatus() async {
        guard await prepareForAuthenticatedRequest() else { return }
        isLoadingBilling = true
        billingErrorMessage = nil

        do {
            billingStatus = try await runAuthorized { client in
                try await client.getBillingStatus()
            }
        } catch let error as RecappiAPIError where error == .unauthorized {
            apply(error: error)
        } catch {
            billingErrorMessage = error.localizedDescription
        }

        isLoadingBilling = false
    }

    func loadMore() async {
        guard let cursor = nextCursor, !cursor.isEmpty else { return }
        guard await prepareForAuthenticatedRequest() else { return }
        isLoadingMore = true

        do {
            let page = try await runAuthorized { client in
                try await client.listRecordings(limit: pageLimit, cursor: cursor)
            }
            let existingIDs = Set(recordings.map(\.id))
            recordings.append(contentsOf: page.items.filter { !existingIDs.contains($0.id) })
            nextCursor = page.nextCursor
            selectDefaultRecordingIfNeeded()
            await refreshLocalSessionLinks()
            state = recordings.isEmpty ? .empty : .loaded
        } catch {
            apply(error: error)
        }

        isLoadingMore = false
    }

    func select(_ recording: CloudRecording) {
        selectedRecordingID = recording.id
        transcriptErrorMessage = nil
        Task { await refreshSelectedDetailIfNeeded() }
    }

    func refreshSelectedDetailIfNeeded() async {
        guard let selectedRecordingID else { return }
        do {
            let detail = try await runAuthorized { client in
                try await client.getRecording(id: selectedRecordingID)
            }
            replaceRecording(detail)
        } catch {
            apply(error: error)
        }
    }

    func loadTranscriptForSelection() async {
        guard let recording = selectedRecording else { return }
        guard transcriptCache[recording.id] == nil else { return }
        isTranscriptLoading = true
        transcriptErrorMessage = nil

        do {
            let transcript = try await runAuthorized { client in
                // `activeTranscriptId` identifies the transcript row, while the
                // backend's optional query parameter is a transcription job id.
                // Cloud Library wants the latest transcript for the recording.
                try await client.getRecordingTranscript(id: recording.id)
            }
            transcriptCache[recording.id] = transcript
        } catch let error as RecappiAPIError where error == .unauthorized {
            apply(error: error)
        } catch {
            transcriptErrorMessage = transcriptMessage(for: error)
        }

        isTranscriptLoading = false
    }

    func copySelectedTranscript() {
        guard let text = selectedTranscript?.text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func downloadSelectedAudio() async {
        guard let recording = selectedRecording else { return }
        isDownloading = true

        do {
            let destination = try downloadDestination(for: recording)
            lastDownloadedAudioURL = try await runAuthorized { client in
                try await client.downloadRecordingAudio(id: recording.id, destination: destination)
            }
        } catch {
            apply(error: error)
        }

        isDownloading = false
    }

    func preparePlaybackAudioForSelection() async {
        guard let recording = selectedRecording else { return }
        guard selectedPlaybackAudioURL == nil else { return }
        isPreparingPlaybackAudio = true
        playbackErrorMessage = nil

        do {
            let destination = try playbackCacheDestination(for: recording)
            if FileManager.default.fileExists(atPath: destination.path) {
                playbackAudioURLsByRecordingID[recording.id] = destination
            } else {
                playbackAudioURLsByRecordingID[recording.id] = try await runAuthorized { client in
                    try await client.downloadRecordingAudio(id: recording.id, destination: destination)
                }
            }
        } catch let error as RecappiAPIError where error == .unauthorized {
            apply(error: error)
        } catch {
            playbackErrorMessage = error.localizedDescription
        }

        isPreparingPlaybackAudio = false
    }

    func syncSelectedRecordingToLocal() async {
        guard let recording = selectedRecording else { return }
        if localSessionURLsByRecordingID[recording.id] != nil { return }

        isSyncingToLocal = true
        transcriptErrorMessage = nil
        playbackErrorMessage = nil

        do {
            let transcript = try await transcriptForSyncIfAvailable(recording)
            let sessionDir = try createSyncedSessionDirectory(for: recording)
            let audioURL = RecordingStore.audioFileURL(in: sessionDir)
                .deletingPathExtension()
                .appendingPathExtension(audioFileExtension(for: recording))

            _ = try await runAuthorized { client in
                try await client.downloadRecordingAudio(id: recording.id, destination: audioURL)
            }

            if let transcript {
                try RecordingStore.saveTranscript(transcript.text, in: sessionDir)
            }
            RecordingStore.saveSessionMetadata(metadata(for: recording), in: sessionDir)
            _ = RecordingStore.saveRemoteManifest(remoteManifest(for: recording, transcript: transcript), in: sessionDir)

            localSessionURLsByRecordingID[recording.id] = sessionDir
            playbackAudioURLsByRecordingID[recording.id] = audioURL
            lastDownloadedAudioURL = audioURL
        } catch let error as RecappiAPIError where error == .unauthorized {
            apply(error: error)
        } catch {
            playbackErrorMessage = error.localizedDescription
        }

        isSyncingToLocal = false
    }

    func revealLastDownloadedAudio() {
        guard let lastDownloadedAudioURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastDownloadedAudioURL])
    }

    func revealSelectedLocalSession() {
        guard let selectedLocalSessionURL else { return }
        NSWorkspace.shared.open(selectedLocalSessionURL)
    }

    func openBillingPortalOrPlans() async {
        guard await prepareForAuthenticatedRequest() else {
            openPlansPage()
            return
        }
        isOpeningBilling = true
        billingErrorMessage = nil

        do {
            let response = try await runAuthorized { client in
                try await client.createBillingPortalSession()
            }
            openURLString(response.url, fallback: plansURL)
        } catch let error as RecappiAPIError {
            switch error {
            case .unauthorized:
                apply(error: error)
            case .http(let statusCode, _) where statusCode == 409:
                // Free-tier accounts do not have a Stripe customer yet.
                openPlansPage()
            default:
                billingErrorMessage = error.localizedDescription
                openPlansPage()
            }
        } catch {
            billingErrorMessage = error.localizedDescription
            openPlansPage()
        }

        isOpeningBilling = false
    }

    func openPlansPage() {
        openURLString(plansURL.absoluteString, fallback: plansURL)
    }

    func deleteSelectedRecording() async {
        guard let recording = selectedRecording else { return }
        isDeleting = true

        do {
            try await runAuthorized { client in
                try await client.deleteRecording(id: recording.id)
            }
            recordings.removeAll { $0.id == recording.id }
            transcriptCache.removeValue(forKey: recording.id)
            playbackAudioURLsByRecordingID.removeValue(forKey: recording.id)
            if selectedRecordingID == recording.id {
                selectedRecordingID = recordings.first?.id
            }
            state = recordings.isEmpty ? .empty : .loaded
        } catch {
            apply(error: error)
        }

        isDeleting = false
    }

    func signIn(with provider: OAuthProvider) async {
        do {
            _ = try await sessionStore.startOAuth(provider: provider, origin: config.effectiveBackendBaseURL)
            await refresh()
        } catch {
            apply(error: error)
        }
    }

    func reconnect() async {
        do {
            _ = try await sessionStore.reconnect(origin: config.effectiveBackendBaseURL)
            await refresh()
        } catch {
            apply(error: error)
        }
    }

    private func prepareForAuthenticatedRequest() async -> Bool {
        guard sessionStore.currentSession != nil || sessionStore.bearerToken() != nil else {
            state = .signedOut
            return false
        }
        return true
    }

    private func runAuthorized<T>(
        _ operation: (RecappiAPIClient) async throws -> T
    ) async throws -> T {
        let origin = config.effectiveBackendBaseURL
        _ = try await sessionStore.ensureAuthorized(origin: origin)
        guard let token = sessionStore.bearerToken() else {
            throw RecappiSessionError.notSignedIn
        }

        do {
            let client = RecappiAPIClient(origin: origin, bearerToken: token)
            return try await operation(client)
        } catch let error as RecappiAPIError where error == .unauthorized {
            _ = try await sessionStore.handleUnauthorized(origin: origin)
            guard let refreshedToken = sessionStore.bearerToken() else {
                throw RecappiSessionError.notSignedIn
            }
            let refreshedClient = RecappiAPIClient(origin: origin, bearerToken: refreshedToken)
            return try await operation(refreshedClient)
        }
    }

    private var plansURL: URL {
        URL(string: config.effectiveBackendBaseURL + "/plans") ?? URL(string: "https://recordmeet.ing/plans")!
    }

    private func openURLString(_ raw: String, fallback: URL) {
        guard let url = URL(string: raw) else {
            NSWorkspace.shared.open(fallback)
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func apply(error: Error) {
        if let apiError = error as? RecappiAPIError, apiError == .unauthorized {
            state = .expired
            return
        }
        if let sessionError = error as? RecappiSessionError {
            switch sessionError {
            case .notSignedIn:
                state = .signedOut
                return
            default:
                break
            }
        }
        state = .failed(error.localizedDescription)
    }

    private func transcriptMessage(for error: Error) -> String {
        if let apiError = error as? RecappiAPIError {
            switch apiError {
            case .http(let statusCode, _) where statusCode == 404:
                return "Transcript is not available for this recording yet."
            default:
                return apiError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func selectDefaultRecordingIfNeeded() {
        if let selectedRecordingID, recordings.contains(where: { $0.id == selectedRecordingID }) {
            return
        }
        selectedRecordingID = recordings.first?.id
    }

    private func replaceRecording(_ recording: CloudRecording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else {
            recordings.insert(recording, at: 0)
            return
        }
        recordings[index] = recording
    }

    private func refreshLocalSessionLinks() async {
        let links = await Task.detached(priority: .utility) {
            Self.localSessionLinks(in: RecordingStore.baseDirectory)
        }.value
        localSessionURLsByRecordingID = links
    }

    nonisolated static func localSessionLinks(
        in baseDirectory: URL,
        fileManager: FileManager = .default
    ) -> [String: URL] {
        guard let sessionDirs = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var links: [String: URL] = [:]
        for sessionDir in sessionDirs.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let values = try? sessionDir.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true,
                  let recordingId = RecordingStore.loadRemoteManifest(in: sessionDir)?.recordingId?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !recordingId.isEmpty,
                  links[recordingId] == nil else {
                continue
            }
            links[recordingId] = sessionDir
        }
        return links
    }

    private func localRecordingAudioURL(for recording: CloudRecording) -> URL? {
        guard let sessionURL = localSessionURLsByRecordingID[recording.id] else { return nil }
        let candidates = [
            RecordingStore.audioFileURL(in: sessionURL),
            RecordingStore.uploadAudioFileURL(in: sessionURL),
            sessionURL.appendingPathComponent("recording.wav"),
            sessionURL.appendingPathComponent("recording.mp3"),
            sessionURL.appendingPathComponent("recording.audio"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func transcriptForSyncIfAvailable(_ recording: CloudRecording) async throws -> TranscriptResponse? {
        if let cached = transcriptCache[recording.id] {
            return cached
        }
        do {
            let transcript = try await runAuthorized { client in
                try await client.getRecordingTranscript(id: recording.id)
            }
            transcriptCache[recording.id] = transcript
            return transcript
        } catch let error as RecappiAPIError {
            if case .http(let statusCode, _) = error, statusCode == 404 {
                return nil
            }
            throw error
        }
    }

    private func createSyncedSessionDirectory(for recording: CloudRecording) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let date = recording.createdAt ?? Date()
        let baseName = formatter.string(from: date)
        var candidate = RecordingStore.baseDirectory.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = RecordingStore.baseDirectory.appendingPathComponent("\(baseName)-cloud-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    private func metadata(for recording: CloudRecording) -> RecordingSessionMetadata {
        var metadata = RecordingSessionMetadata.capture(
            sourceTitle: recording.sourceTitle ?? recording.title ?? "Recappi Cloud",
            sourceAppName: recording.sourceAppName,
            sourceBundleID: recording.sourceAppBundleID
        )
        metadata.summaryTitle = recording.summaryTitle ?? recording.title
        return metadata
    }

    private func remoteManifest(for recording: CloudRecording, transcript: TranscriptResponse?) -> RemoteSessionManifest {
        var manifest = RemoteSessionManifest.stage("synced")
        manifest.recordingId = recording.id
        manifest.transcriptId = transcript?.id
        manifest.uploadFilename = "recording.\(audioFileExtension(for: recording))"
        return manifest
    }

    private func downloadDestination(for recording: CloudRecording) throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let directory = downloads.appendingPathComponent("Recappi Mini", isDirectory: true)
        let basename = sanitizedFilename(recording.title ?? "recording-\(recording.id)")
        let ext = audioFileExtension(for: recording)
        return directory.appendingPathComponent("\(basename).\(ext)", isDirectory: false)
    }

    private func playbackCacheDestination(for recording: CloudRecording) throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = caches
            .appendingPathComponent("Recappi Mini", isDirectory: true)
            .appendingPathComponent("Cloud Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(recording.id).\(audioFileExtension(for: recording))")
    }

    private func audioFileExtension(for recording: CloudRecording) -> String {
        switch recording.contentType?.lowercased() {
        case "audio/wav", "audio/x-wav":
            return "wav"
        case "audio/mpeg", "audio/mp3":
            return "mp3"
        case "audio/mp4", "audio/m4a", "video/mp4":
            return "m4a"
        default:
            return "audio"
        }
    }

    private func sanitizedFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "recording" : String(cleaned.prefix(96))
    }
}
