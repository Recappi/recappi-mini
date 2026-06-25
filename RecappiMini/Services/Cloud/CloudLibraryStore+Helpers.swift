import AppKit
import Foundation

@MainActor
extension CloudLibraryStore {
    func selectDefaultRecordingIfNeeded() {
        if let selectedRecordingID, recordings.contains(where: { $0.id == selectedRecordingID }) {
            return
        }
        selectedRecordingID = recordings.first?.id
    }

    func replaceRecording(_ recording: CloudRecording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else {
            recordings.insert(recording, at: 0)
            recordings = Self.deduplicatedRecordings(recordings)
            return
        }
        recordings[index] = recording
        recordings = Self.deduplicatedRecordings(recordings)
    }

    func applySummaryTitleFromTranscript(_ transcript: TranscriptResponse, to recordingID: String) {
        guard let title = transcript.summaryInsights?.title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let recording = recordings.first(where: { $0.id == recordingID }) else {
            return
        }
        replaceRecording(recording.replacingSummaryTitle(title))
    }

    func mergeWithCachedRecordingDetails(_ incoming: [CloudRecording]) -> [CloudRecording] {
        let cachedByID = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        return Self.deduplicatedRecordings(incoming.map { recording in
            guard let cached = cachedByID[recording.id] else { return recording }
            return recording.mergingCachedDetail(from: cached)
        })
    }

    func mergeWithLocalOnlyRecordings(
        _ incoming: [CloudRecording],
        localOnlyRecordings: [CloudRecording]
    ) -> [CloudRecording] {
        let cachedByID = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        var merged = Self.deduplicatedRecordings(incoming)
        var mergedIDs = Set(merged.map(\.id))

        for localRecording in localOnlyRecordings where !mergedIDs.contains(localRecording.id) {
            if let cached = cachedByID[localRecording.id] {
                merged.append(localRecording.mergingCachedDetail(from: cached))
            } else {
                merged.append(localRecording)
            }
            mergedIDs.insert(localRecording.id)
        }

        return merged.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
    }

    nonisolated static func deduplicatedRecordings(_ recordings: [CloudRecording]) -> [CloudRecording] {
        var seenIDs = Set<String>()
        return recordings.filter { recording in
            seenIDs.insert(recording.id).inserted
        }
    }

    func loadLocalOnlyRecordings() async -> [CloudRecording] {
        let account = cacheContext()
        return await Task.detached(priority: .utility) {
            Self.localOnlyRecordings(in: RecordingStore.baseDirectory, currentAccount: account)
        }.value
    }

    @discardableResult
    func mergeLocalOnlyRecordingsFromDisk() async -> Bool {
        await refreshUnattributedLocalSessionCount()
        let localOnlyRecordings = await loadLocalOnlyRecordings()
        guard !localOnlyRecordings.isEmpty else { return false }

        recordings = mergeWithLocalOnlyRecordings(
            recordings,
            localOnlyRecordings: localOnlyRecordings
        )
        selectDefaultRecordingIfNeeded()
        await refreshLocalSessionLinks()
        state = recordings.isEmpty ? .empty : .loaded
        return true
    }

    func setTranscriptLoading(_ loading: Bool, for recordingID: String) {
        isTranscriptLoading = updateLoadingIDs(&transcriptLoadingRecordingIDs, loading, recordingID: recordingID)
    }

    func setJobHistoryLoading(_ loading: Bool, for recordingID: String) {
        isJobHistoryLoading = updateLoadingIDs(&jobHistoryLoadingRecordingIDs, loading, recordingID: recordingID)
    }

    private func updateLoadingIDs(
        _ ids: inout Set<String>,
        _ loading: Bool,
        recordingID: String
    ) -> Bool {
        if loading {
            ids.insert(recordingID)
        } else {
            ids.remove(recordingID)
        }
        return !ids.isEmpty
    }


    func refreshLocalSessionLinks() async {
        let account = cacheContext()
        let links = await Task.detached(priority: .utility) {
            Self.localSessionLinks(in: RecordingStore.baseDirectory, currentAccount: account)
        }.value
        localSessionURLsByRecordingID = links
    }

    // Refresh the count of unattributed local sessions so the UI can offer the
    // "claim to current account" action. Zero when signed out.
    func refreshUnattributedLocalSessionCount() async {
        guard cacheContext() != nil else {
            if unattributedLocalSessionCount != 0 { unattributedLocalSessionCount = 0 }
            return
        }
        let count = await Task.detached(priority: .utility) {
            Self.unattributedLocalOnlySessions(in: RecordingStore.baseDirectory).count
        }.value
        if unattributedLocalSessionCount != count { unattributedLocalSessionCount = count }
    }

    func loadLiveCaptionTranscriptForSelection() async {
        guard let recordingID = selectedRecordingID else { return }
        if localSessionURLsByRecordingID[recordingID] == nil {
            await refreshLocalSessionLinks()
        }
        guard selectedRecordingID == recordingID else { return }

        guard let sessionURL = localSessionURLsByRecordingID[recordingID] else {
            liveCaptionTranscriptStatesByRecordingID[recordingID] = .unavailable
            return
        }

        let state = await Task.detached(priority: .utility) {
            LiveCaptionTranscriptReader.load(from: sessionURL)
        }.value

        guard selectedRecordingID == recordingID else { return }
        liveCaptionTranscriptStatesByRecordingID[recordingID] = state
    }

    // Account-scoping note: sessions that already have a cloud `recordingId` are
    // inherently account-scoped (a cloud id only resolves within its owner's cloud
    // list), so their links stay unfiltered. Local-only sessions (no cloud id) are
    // the cross-account leak risk, so they are gated by the current account stamp.
    nonisolated static func localSessionLinks(
        in baseDirectory: URL,
        currentAccount: (userId: String, backendOrigin: String)?,
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
            guard values?.isDirectory == true else {
                continue
            }

            let manifest = RecordingStore.loadRemoteManifest(in: sessionDir)
            logPartialAccountStampIfNeeded(manifest, sessionDir: sessionDir)
            let remoteID = manifest?.recordingId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hasRemoteID = remoteID?.isEmpty == false
            if !hasRemoteID && !sessionMatchesAccount(manifest, currentAccount: currentAccount) {
                continue // local-only draft from another / no account — don't link
            }
            let recordingId = hasRemoteID
                ? remoteID!
                : "local-\(sessionDir.lastPathComponent)"
            guard links[recordingId] == nil else { continue }
            links[recordingId] = sessionDir
        }
        return links
    }

    nonisolated static func localOnlyRecordings(
        in baseDirectory: URL,
        currentAccount: (userId: String, backendOrigin: String)?,
        fileManager: FileManager = .default
    ) -> [CloudRecording] {
        // Signed out → never surface any account's local-only drafts.
        guard currentAccount != nil else { return [] }
        guard let sessionDirs = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return sessionDirs
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            .compactMap { sessionDir -> CloudRecording? in
                let values = try? sessionDir.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { return nil }

                let manifest = RecordingStore.loadRemoteManifest(in: sessionDir)
                let remoteID = manifest?.recordingId?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard remoteID?.isEmpty != false else { return nil }

                logPartialAccountStampIfNeeded(manifest, sessionDir: sessionDir)
                guard sessionMatchesAccount(manifest, currentAccount: currentAccount) else {
                    return nil // unattributed / other account → hidden until claimed
                }

                return SessionProcessor.localRecordingPlaceholder(
                    sessionDir: sessionDir,
                    duration: 0,
                    status: localOnlyRecordingStatus(from: manifest)
                )
            }
    }

    private nonisolated static func sessionMatchesAccount(
        _ manifest: RemoteSessionManifest?,
        currentAccount: (userId: String, backendOrigin: String)?
    ) -> Bool {
        guard let manifest, let account = currentAccount else { return false }
        return manifest.belongsToAccount(userId: account.userId, backendOrigin: account.backendOrigin)
    }

    private nonisolated static func logPartialAccountStampIfNeeded(
        _ manifest: RemoteSessionManifest?,
        sessionDir: URL
    ) {
        guard manifest?.hasPartialAccountStamp == true else { return }
        DiagnosticsLog.warning(
            "local-session",
            "partial account stamp, treating as unattributed: \(sessionDir.lastPathComponent)"
        )
    }

    // Local-only sessions with no usable account stamp (legacy or recorded while
    // signed out). These are hidden from every account until explicitly claimed.
    nonisolated static func unattributedLocalOnlySessions(
        in baseDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let sessionDirs = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return sessionDirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { sessionDir in
                let manifest = RecordingStore.loadRemoteManifest(in: sessionDir)
                let remoteID = manifest?.recordingId?.trimmingCharacters(in: .whitespacesAndNewlines)
                let isLocalOnly = remoteID?.isEmpty != false
                return isLocalOnly && (manifest?.isAccountUnattributed ?? true)
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Attribute a single unattributed local session to the current account.
    /// Returns false when signed out or when the session is already stamped to an
    /// account — claim never reassigns across accounts (anti-theft guardrail).
    @discardableResult
    func claimUnattributedLocalSession(at sessionDir: URL) -> Bool {
        guard let account = cacheContext() else { return false }
        let manifest = RecordingStore.loadRemoteManifest(in: sessionDir)
        guard manifest?.isAccountUnattributed ?? true else { return false }
        RecordingStore.stampAccount(account, in: sessionDir)
        return true
    }

    /// Claim every unattributed local session for the current account, returning
    /// how many were claimed. Refreshes the recordings list when any were claimed.
    @discardableResult
    func claimAllUnattributedLocalSessions() async -> Int {
        guard cacheContext() != nil else { return 0 }
        let dirs = await Task.detached(priority: .utility) {
            Self.unattributedLocalOnlySessions(in: RecordingStore.baseDirectory)
        }.value
        var claimed = 0
        for dir in dirs where claimUnattributedLocalSession(at: dir) { claimed += 1 }
        if claimed > 0 { await mergeLocalOnlyRecordingsFromDisk() }
        return claimed
    }

    private nonisolated static func localOnlyRecordingStatus(
        from manifest: RemoteSessionManifest?
    ) -> CloudRecordingStatus {
        guard let manifest else { return .failed }

        switch manifest.stage {
        case "uploadFailed", "transcriptionFailed":
            return .failed
        case "done", "synced":
            return .ready
        default:
            return .uploading
        }
    }

    func localRecordingAudioURL(for recording: CloudRecording) -> URL? {
        guard let sessionURL = localSessionURLsByRecordingID[recording.id] else { return nil }
        if let primary = SessionProcessor.primaryAudioFileURL(
            in: sessionURL,
            manifest: RecordingStore.loadRemoteManifest(in: sessionURL)
        ) {
            return primary
        }
        let candidates = [
            RecordingStore.audioFileURL(in: sessionURL),
            RecordingStore.uploadAudioFileURL(in: sessionURL),
            sessionURL.appendingPathComponent("recording.wav"),
            sessionURL.appendingPathComponent("recording.mp3"),
            sessionURL.appendingPathComponent("recording.audio"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func transcriptForSyncIfAvailable(_ recording: CloudRecording) async throws -> TranscriptResponse? {
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

    func syncTranscriptToLocalSessionIfLinked(
        recording: CloudRecording,
        transcript: TranscriptResponse,
        job: TranscriptionJob? = nil
    ) throws {
        guard let sessionDir = localSessionURLsByRecordingID[recording.id] else { return }
        try RecordingStore.saveTranscriptArtifacts(transcript, in: sessionDir)
        RecordingStore.saveSessionMetadata(metadata(for: recording), in: sessionDir)

        var manifest = RecordingStore.loadRemoteManifest(in: sessionDir)
            ?? remoteManifest(for: recording, transcript: transcript)
        manifest.recordingId = recording.id
        manifest.transcriptId = transcript.id
        manifest.uploadFilename = manifest.uploadFilename ?? "recording.\(audioFileExtension(for: recording))"
        if let job {
            manifest.jobId = job.id
            manifest.provider = job.provider
            manifest.model = job.model
            manifest.stage = "done"
        } else if manifest.stage != "done" {
            manifest.stage = "synced"
        }
        _ = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)
    }

    func syncSelectedTranscriptArtifactsIfPossible() {
        guard let recording = selectedRecording,
              let transcript = transcriptCache[recording.id] else {
            return
        }
        do {
            try syncTranscriptToLocalSessionIfLinked(recording: recording, transcript: transcript)
        } catch {
            DiagnosticsLog.error(
                "cloud",
                "transcript.sync_local.failed recordingID=\(recording.id) \(DiagnosticsLog.errorSummary(error))"
            )
            playbackErrorMessage = NetworkErrorPresenter.userFacingMessage(for: error)
        }
    }

    func createSyncedSessionDirectory(for recording: CloudRecording) throws -> URL {
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

    func metadata(for recording: CloudRecording) -> RecordingSessionMetadata {
        var metadata = RecordingSessionMetadata.capture(
            sourceTitle: recording.sourceTitle ?? recording.title ?? "Recappi Cloud",
            sourceAppName: recording.sourceAppName,
            sourceBundleID: recording.sourceAppBundleID
        )
        metadata.summaryTitle = recording.summaryTitle ?? recording.title
        return metadata
    }

    func remoteManifest(for recording: CloudRecording, transcript: TranscriptResponse?) -> RemoteSessionManifest {
        var manifest = RemoteSessionManifest.stage("synced")
        manifest.recordingId = recording.id
        manifest.transcriptId = transcript?.id
        manifest.uploadFilename = "recording.\(audioFileExtension(for: recording))"
        return manifest
    }

    func remoteManifest(
        for recording: CloudRecording,
        transcript: TranscriptResponse,
        job: TranscriptionJob
    ) -> RemoteSessionManifest {
        var manifest = remoteManifest(for: recording, transcript: transcript)
        manifest.jobId = job.id
        manifest.provider = job.provider
        manifest.model = job.model
        manifest.stage = "done"
        return manifest
    }

}

extension CloudRecording {
    func replacingSummaryTitle(_ nextSummaryTitle: String) -> CloudRecording {
        CloudRecording(
            id: id,
            userId: userId,
            title: title,
            summaryTitle: nextSummaryTitle,
            sourceTitle: sourceTitle,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID,
            r2Key: r2Key,
            r2UploadId: r2UploadId,
            status: status,
            sizeBytes: sizeBytes,
            durationMs: durationMs,
            sampleRate: sampleRate,
            channels: channels,
            contentType: contentType,
            activeTranscriptId: activeTranscriptId,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

enum CloudLibraryError: LocalizedError {
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .transcriptionFailed(let message):
            return "Recappi transcription failed: \(message)"
        }
    }
}
