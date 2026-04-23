import Foundation

@MainActor
final class SessionProcessor {
    static let shared = SessionProcessor()

    private init() {}

    func process(
        sessionDir: URL,
        duration: Int,
        updatePhase: @escaping @MainActor @Sendable (ProcessingPhase) -> Void
    ) async throws -> RecordingResult {
        let origin = AppConfig.shared.effectiveBackendBaseURL
        var attemptedReauthentication = false

        while true {
            do {
                return try await processOnce(
                    sessionDir: sessionDir,
                    duration: duration,
                    updatePhase: updatePhase
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
        updatePhase: @escaping @MainActor @Sendable (ProcessingPhase) -> Void
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
        let recordingURL = RecordingStore.audioFileURL(in: sessionDir)

        let uploadedRecording = try await uploadRecordingAsset(
            primaryURL: recordingURL,
            sessionDir: sessionDir,
            client: client,
            manifest: manifest,
            updatePhase: updatePhase
        )
        manifest = uploadedRecording.manifest

        let language = config.normalizedCloudLanguage
        updatePhase(.startingTranscription)
        let start = try await client.startTranscription(recordingId: uploadedRecording.recordingId, language: language)
        manifest.jobId = start.jobId
        manifest.stage = "startingTranscription"
        manifest = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)

        let job = try await pollForCompletion(
            client: client,
            recordingId: uploadedRecording.recordingId,
            initial: start,
            updatePhase: updatePhase
        )

        manifest.provider = job.provider
        manifest.model = job.model
        manifest.transcriptId = job.transcriptId
        manifest.stage = "fetchingTranscript"
        manifest = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)

        updatePhase(.fetchingTranscript)
        let transcript = try await client.getTranscript(recordingId: uploadedRecording.recordingId, jobId: job.id)
        try RecordingStore.saveTranscript(transcript.text, in: sessionDir)

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

    private func uploadRecordingAsset(
        primaryURL: URL,
        sessionDir: URL,
        client: RecappiAPIClient,
        manifest: RemoteSessionManifest,
        updatePhase: @escaping @MainActor @Sendable (ProcessingPhase) -> Void
    ) async throws -> UploadedRecordingAsset {
        do {
            return try await uploadAndComplete(
                fileURL: primaryURL,
                client: client,
                manifest: manifest,
                updatePhase: updatePhase
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
                    updatePhase: updatePhase
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
        updatePhase: @escaping @MainActor @Sendable (ProcessingPhase) -> Void
    ) async throws -> UploadedRecordingAsset {
        var nextManifest = manifest
        nextManifest.uploadFilename = fileURL.lastPathComponent
        nextManifest.errorMessage = nil
        nextManifest = RecordingStore.saveRemoteManifest(nextManifest, in: fileURL.deletingLastPathComponent())

        updatePhase(.creatingRecording)
        let created = try await client.createRecording(title: fileURL.deletingLastPathComponent().lastPathComponent)
        nextManifest.recordingId = created.id
        nextManifest.jobId = nil
        nextManifest.transcriptId = nil
        nextManifest.stage = "creatingRecording"
        nextManifest = RecordingStore.saveRemoteManifest(nextManifest, in: fileURL.deletingLastPathComponent())

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
            _ = try await client.completeRecording(recordingId: created.id, parts: parts)
            nextManifest.stage = "completingUpload"
            nextManifest.errorMessage = nil
            nextManifest = RecordingStore.saveRemoteManifest(nextManifest, in: fileURL.deletingLastPathComponent())

            return UploadedRecordingAsset(recordingId: created.id, manifest: nextManifest)
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
        updatePhase: @escaping @MainActor @Sendable (ProcessingPhase) -> Void
    ) async throws -> TranscriptionJob {
        if initial.status == .succeeded {
            return try await client.getJob(jobId: initial.jobId)
        }

        while true {
            let job = try await client.getJob(jobId: initial.jobId)
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

    private func bearerToken() throws -> String {
        guard let value = AuthSessionStore.shared.bearerToken() else {
            throw RecappiSessionError.notSignedIn
        }
        return value
    }
}

private struct UploadedRecordingAsset {
    let recordingId: String
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
