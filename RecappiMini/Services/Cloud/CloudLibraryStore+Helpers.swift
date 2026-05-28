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
        await Task.detached(priority: .utility) {
            Self.localOnlyRecordings(in: RecordingStore.baseDirectory)
        }.value
    }

    @discardableResult
    func mergeLocalOnlyRecordingsFromDisk() async -> Bool {
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
            guard values?.isDirectory == true else {
                continue
            }

            let remoteID = RecordingStore.loadRemoteManifest(in: sessionDir)?.recordingId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let recordingId = remoteID?.isEmpty == false
                ? remoteID!
                : "local-\(sessionDir.lastPathComponent)"
            guard links[recordingId] == nil else { continue }
            links[recordingId] = sessionDir
        }
        return links
    }

    nonisolated static func localOnlyRecordings(
        in baseDirectory: URL,
        fileManager: FileManager = .default
    ) -> [CloudRecording] {
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

                return SessionProcessor.localRecordingPlaceholder(
                    sessionDir: sessionDir,
                    duration: 0,
                    status: localOnlyRecordingStatus(from: manifest)
                )
            }
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
