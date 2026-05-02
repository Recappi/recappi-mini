import Foundation

@MainActor
final class SessionProcessor {
    static let shared = SessionProcessor()

    private init() {}

    func process(
        sessionDir: URL,
        duration: Int,
        updatePhase: @escaping @MainActor @Sendable (ProcessingPhase) -> Void,
        onCloudRecordingUpdated: @escaping @MainActor @Sendable (CloudRecording, TranscriptionJob?) -> Void = { _, _ in }
    ) async throws -> RecordingResult {
        let origin = AppConfig.shared.effectiveBackendBaseURL
        var attemptedReauthentication = false

        while true {
            do {
                return try await processOnce(
                    sessionDir: sessionDir,
                    duration: duration,
                    updatePhase: updatePhase,
                    onCloudRecordingUpdated: onCloudRecordingUpdated
                )
            } catch let error as RecappiAPIError where error == .unauthorized && !attemptedReauthentication {
                attemptedReauthentication = true
                updatePhase(.verifyingSession)
                _ = try await AuthSessionStore.shared.handleUnauthorized(origin: origin)
            } catch {
                throw error
            }
        }
    }

    private func processOnce(
        sessionDir: URL,
        duration: Int,
        updatePhase: @escaping @MainActor @Sendable (ProcessingPhase) -> Void,
        onCloudRecordingUpdated: @escaping @MainActor @Sendable (CloudRecording, TranscriptionJob?) -> Void
    ) async throws -> RecordingResult {
        let config = AppConfig.shared
        guard config.cloudEnabled else {
            throw SessionProcessorError.cloudDisabled
        }

        updatePhase(.verifyingSession)
        let session = try await AuthSessionStore.shared.ensureAuthorized(origin: config.effectiveBackendBaseURL)
        let client = RecappiAPIClient(origin: session.backendOrigin, bearerToken: try bearerToken())

        var manifest = RecordingStore.loadRemoteManifest(in: sessionDir) ?? .stage("verifyingSession")
        manifest = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)
        if manifest.stage == "done",
           let transcript = RecordingStore.loadTranscript(in: sessionDir) {
            return RecordingResult(
                folderURL: sessionDir,
                transcript: transcript,
                duration: duration
            )
        }
        let recordingURL = RecordingStore.audioFileURL(in: sessionDir)

        let uploadedRecording: UploadedRecordingAsset
        if let recordingId = Self.reusableRecordingID(in: manifest) {
            let metadata = RecordingStore.loadSessionMetadata(in: sessionDir)
            uploadedRecording = UploadedRecordingAsset(
                recordingId: recordingId,
                recording: Self.localCloudRecording(
                    id: recordingId,
                    title: metadata?.cloudRecordingTitle ?? sessionDir.lastPathComponent,
                    r2Key: nil,
                    status: Self.cloudRecordingStatus(fromManifestStage: manifest.stage),
                    duration: duration,
                    contentType: nil,
                    sessionDir: sessionDir
                ),
                manifest: manifest
            )
        } else {
            uploadedRecording = try await uploadRecordingAsset(
                primaryURL: recordingURL,
                sessionDir: sessionDir,
                client: client,
                manifest: manifest,
                duration: duration,
                updatePhase: updatePhase,
                onCloudRecordingUpdated: onCloudRecordingUpdated
            )
        }
        manifest = uploadedRecording.manifest

        if Self.reusableTranscriptID(in: manifest) != nil {
            updatePhase(.fetchingTranscript)
            let transcript = try await client.getRecordingTranscript(id: uploadedRecording.recordingId)
            try RecordingStore.saveTranscriptArtifacts(transcript, in: sessionDir)
            manifest.stage = "done"
            manifest.errorMessage = nil
            manifest.transcriptId = transcript.id
            _ = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)
            return RecordingResult(
                folderURL: sessionDir,
                transcript: transcript.text,
                duration: duration
            )
        }

        let language = config.normalizedCloudLanguage
        let start: StartTranscriptionResponse
        if let jobId = Self.reusableJobID(in: manifest) {
            start = StartTranscriptionResponse(
                jobId: jobId,
                status: .queued,
                transcriptId: manifest.transcriptId
            )
        } else {
            updatePhase(.startingTranscription)
            start = try await client.startTranscription(recordingId: uploadedRecording.recordingId, language: language)
            manifest.jobId = start.jobId
            manifest.stage = "startingTranscription"
            manifest = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)
            onCloudRecordingUpdated(uploadedRecording.recording, Self.localJobPlaceholder(from: start))
        }

        let job: TranscriptionJob
        do {
            job = try await pollForCompletion(
                client: client,
                recordingId: uploadedRecording.recordingId,
                initial: start,
                updatePhase: updatePhase,
                onJobUpdate: { job in onCloudRecordingUpdated(uploadedRecording.recording, job) }
            )
        } catch {
            manifest.errorMessage = error.localizedDescription
            manifest.stage = "transcriptionFailed"
            _ = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)
            throw error
        }

        manifest.provider = job.provider
        manifest.model = job.model
        manifest.transcriptId = job.transcriptId
        manifest.stage = "fetchingTranscript"
        manifest = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)

        updatePhase(.fetchingTranscript)
        let transcript = try await client.getTranscript(recordingId: uploadedRecording.recordingId, jobId: job.id)
        try RecordingStore.saveTranscriptArtifacts(transcript, in: sessionDir)

        manifest.stage = "done"
        manifest.errorMessage = nil
        manifest.transcriptId = transcript.id
        _ = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)

        return RecordingResult(
            folderURL: sessionDir,
            transcript: transcript.text,
            duration: duration
        )
    }

    nonisolated static func reusableRecordingID(in manifest: RemoteSessionManifest) -> String? {
        guard let recordingId = cleanID(manifest.recordingId) else { return nil }
        if cleanID(manifest.jobId) != nil || cleanID(manifest.transcriptId) != nil {
            return recordingId
        }

        switch manifest.stage {
        case "completingUpload", "startingTranscription", "fetchingTranscript", "done", "synced":
            return recordingId
        default:
            return nil
        }
    }

    nonisolated static func reusableJobID(in manifest: RemoteSessionManifest) -> String? {
        guard manifest.stage != "transcriptionFailed" else { return nil }
        return cleanID(manifest.jobId)
    }

    nonisolated static func reusableTranscriptID(in manifest: RemoteSessionManifest) -> String? {
        guard manifest.stage != "transcriptionFailed" else { return nil }
        return cleanID(manifest.transcriptId)
    }

    private nonisolated static func cleanID(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private func uploadRecordingAsset(
        primaryURL: URL,
        sessionDir: URL,
        client: RecappiAPIClient,
        manifest: RemoteSessionManifest,
        duration: Int,
        updatePhase: @escaping @MainActor @Sendable (ProcessingPhase) -> Void,
        onCloudRecordingUpdated: @escaping @MainActor @Sendable (CloudRecording, TranscriptionJob?) -> Void
    ) async throws -> UploadedRecordingAsset {
        do {
            return try await uploadAndComplete(
                fileURL: primaryURL,
                client: client,
                manifest: manifest,
                duration: duration,
                updatePhase: updatePhase,
                onCloudRecordingUpdated: onCloudRecordingUpdated
            )
        } catch {
            guard shouldRetryWithWaveFallback(after: error, primaryURL: primaryURL) else {
                var failedManifest = manifest
                failedManifest.errorMessage = error.localizedDescription
                failedManifest.stage = "uploadFailed"
                _ = RecordingStore.saveRemoteManifest(failedManifest, in: sessionDir)
                throw error
            }

            updatePhase(.preparingUploadWav)
            let fallbackURL = try await UploadAudioExporter.ensureUploadAudio(for: sessionDir)

            do {
                return try await uploadAndComplete(
                    fileURL: fallbackURL,
                    client: client,
                    manifest: manifest,
                    duration: duration,
                    updatePhase: updatePhase,
                    onCloudRecordingUpdated: onCloudRecordingUpdated
                )
            } catch {
                var failedManifest = manifest
                failedManifest.uploadFilename = fallbackURL.lastPathComponent
                failedManifest.errorMessage = error.localizedDescription
                failedManifest.stage = "uploadFailed"
                _ = RecordingStore.saveRemoteManifest(failedManifest, in: sessionDir)
                throw error
            }
        }
    }

    private func uploadAndComplete(
        fileURL: URL,
        client: RecappiAPIClient,
        manifest: RemoteSessionManifest,
        duration: Int,
        updatePhase: @escaping @MainActor @Sendable (ProcessingPhase) -> Void,
        onCloudRecordingUpdated: @escaping @MainActor @Sendable (CloudRecording, TranscriptionJob?) -> Void
    ) async throws -> UploadedRecordingAsset {
        var nextManifest = manifest
        nextManifest.uploadFilename = fileURL.lastPathComponent
        nextManifest.errorMessage = nil
        nextManifest = RecordingStore.saveRemoteManifest(nextManifest, in: fileURL.deletingLastPathComponent())

        updatePhase(.creatingRecording)
        let sessionDir = fileURL.deletingLastPathComponent()
        let recordingTitle = RecordingStore.loadSessionMetadata(in: sessionDir)?.cloudRecordingTitle
            ?? sessionDir.lastPathComponent
        let created = try await client.createRecording(title: recordingTitle)
        nextManifest.recordingId = created.id
        nextManifest.jobId = nil
        nextManifest.transcriptId = nil
        nextManifest.stage = "creatingRecording"
        nextManifest = RecordingStore.saveRemoteManifest(nextManifest, in: fileURL.deletingLastPathComponent())
        var localRecording = Self.localCloudRecording(
            id: created.id,
            title: recordingTitle,
            r2Key: created.r2Key,
            status: .uploading,
            duration: duration,
            contentType: nil,
            sessionDir: sessionDir
        )
        onCloudRecordingUpdated(localRecording, nil)

        do {
            updatePhase(.uploading(progress: 0))
            let parts = try await client.uploadRecording(
                recordingId: created.id,
                fileURL: fileURL,
                partSize: created.partSize
            ) { progress in
                updatePhase(.uploading(progress: progress))
            }

            updatePhase(.completingUpload)
            let completed = try await client.completeRecording(recordingId: created.id, parts: parts)
            nextManifest.stage = "completingUpload"
            nextManifest.errorMessage = nil
            nextManifest = RecordingStore.saveRemoteManifest(nextManifest, in: fileURL.deletingLastPathComponent())
            localRecording = Self.localCloudRecording(
                id: created.id,
                title: recordingTitle,
                r2Key: created.r2Key,
                status: Self.cloudRecordingStatus(from: completed.status),
                duration: duration,
                contentType: completed.contentType,
                sessionDir: sessionDir
            )
            onCloudRecordingUpdated(localRecording, nil)

            return UploadedRecordingAsset(recordingId: created.id, recording: localRecording, manifest: nextManifest)
        } catch {
            await client.abortRecordingIfNeeded(recordingId: created.id)
            throw error
        }
    }

    private func shouldRetryWithWaveFallback(after error: Error, primaryURL: URL) -> Bool {
        guard primaryURL.pathExtension.lowercased() != "wav" else { return false }

        if let apiError = error as? RecappiAPIError {
            switch apiError {
            case .http(_, let message):
                let lower = message.lowercased()
                return lower.contains("wav")
                    || lower.contains("header")
                    || lower.contains("audio format")
                    || lower.contains("unsupported")
            case .invalidResponse:
                return true
            case .unauthorized, .invalidURL:
                return false
            }
        }

        if error is URLError {
            return true
        }

        return false
    }

    private func pollForCompletion(
        client: RecappiAPIClient,
        recordingId: String,
        initial: StartTranscriptionResponse,
        updatePhase: @escaping @MainActor @Sendable (ProcessingPhase) -> Void,
        onJobUpdate: @escaping @MainActor @Sendable (TranscriptionJob) -> Void
    ) async throws -> TranscriptionJob {
        if initial.status == .succeeded {
            let job = try await client.getJob(jobId: initial.jobId)
            onJobUpdate(job)
            return job
        }

        while true {
            let job = try await client.getJob(jobId: initial.jobId)
            onJobUpdate(job)
            updatePhase(.polling(jobStatus: job.status.rawValue))
            switch job.status {
            case .queued, .running:
                try await Task.sleep(for: .seconds(2))
            case .succeeded:
                return job
            case .failed:
                throw SessionProcessorError.jobFailed(job.error ?? "Transcription failed")
            }
        }
    }

    private nonisolated static func localCloudRecording(
        id: String,
        title: String,
        r2Key: String?,
        status: CloudRecordingStatus,
        duration: Int,
        contentType: String?,
        sessionDir: URL
    ) -> CloudRecording {
        let metadata = RecordingStore.loadSessionMetadata(in: sessionDir)
        return CloudRecording(
            id: id,
            userId: nil,
            title: title,
            summaryTitle: metadata?.summaryTitle,
            sourceTitle: metadata?.sourceTitle,
            sourceAppName: metadata?.sourceAppName,
            sourceAppBundleID: metadata?.sourceBundleID,
            r2Key: r2Key,
            r2UploadId: nil,
            status: status,
            sizeBytes: nil,
            durationMs: duration > 0 ? duration * 1000 : nil,
            sampleRate: nil,
            channels: nil,
            contentType: contentType,
            activeTranscriptId: nil,
            createdAt: metadata.flatMap { ISO8601DateFormatter().date(from: $0.startedAt) } ?? Date(),
            updatedAt: Date()
        )
    }

    private nonisolated static func cloudRecordingStatus(from raw: String) -> CloudRecordingStatus {
        switch raw {
        case "uploading":
            return .uploading
        case "ready":
            return .ready
        case "failed":
            return .failed
        case "aborted":
            return .aborted
        default:
            return .unknown(raw)
        }
    }

    private nonisolated static func cloudRecordingStatus(fromManifestStage stage: String) -> CloudRecordingStatus {
        switch stage {
        case "creatingRecording", "uploading":
            return .uploading
        case "uploadFailed", "transcriptionFailed":
            return .failed
        default:
            return .ready
        }
    }

    private nonisolated static func localJobPlaceholder(from response: StartTranscriptionResponse) -> TranscriptionJob {
        TranscriptionJob(
            id: response.jobId,
            status: response.status,
            transcriptId: response.transcriptId,
            provider: "Recappi Cloud",
            model: "Transcription",
            language: nil,
            prompt: nil,
            error: nil,
            attempts: nil,
            enqueuedAt: Int(Date().timeIntervalSince1970),
            startedAt: nil,
            finishedAt: nil
        )
    }

    private func bearerToken() throws -> String {
        guard let value = AuthSessionStore.shared.bearerToken() else {
            throw RecappiSessionError.notSignedIn
        }
        return value
    }
}

private struct UploadedRecordingAsset {
    let recordingId: String
    let recording: CloudRecording
    let manifest: RemoteSessionManifest
}

enum SessionProcessorError: LocalizedError {
    case cloudDisabled
    case jobFailed(String)

    var errorDescription: String? {
        switch self {
        case .cloudDisabled:
            return "Recappi Cloud is disabled in Settings."
        case .jobFailed(let error):
            return "Recappi transcription failed: \(error)"
        }
    }
}
