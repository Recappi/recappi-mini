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
        let config = AppConfig.shared
        guard config.cloudEnabled else {
            throw SessionProcessorError.cloudDisabled
        }

        updatePhase(.verifyingSession)
        let session = try await CookieSessionStore.shared.ensureAuthorized(origin: config.effectiveBackendBaseURL)
        let client = RecappiAPIClient(origin: session.backendOrigin, cookieValue: try cookieValue())

        updatePhase(.preparingUploadWav)
        let uploadURL = try await UploadAudioExporter.ensureUploadAudio(for: sessionDir)

        var manifest = RecordingStore.loadRemoteManifest(in: sessionDir) ?? .stage("verifyingSession")
        manifest.uploadFilename = uploadURL.lastPathComponent
        manifest = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)

        updatePhase(.creatingRecording)
        let created = try await client.createRecording(title: sessionDir.lastPathComponent)
        manifest.recordingId = created.id
        manifest.stage = "creatingRecording"
        manifest = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)

        do {
            updatePhase(.uploading(progress: 0))
            let parts = try await client.uploadRecording(
                recordingId: created.id,
                fileURL: uploadURL,
                partSize: created.partSize
            ) { progress in
                updatePhase(.uploading(progress: progress))
            }

            updatePhase(.completingUpload)
            _ = try await client.completeRecording(recordingId: created.id, parts: parts)
            manifest.stage = "completingUpload"
            manifest = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)
        } catch {
            await client.abortRecordingIfNeeded(recordingId: created.id)
            manifest.errorMessage = error.localizedDescription
            manifest.stage = "uploadFailed"
            _ = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)
            throw error
        }

        let language = config.normalizedCloudLanguage
        updatePhase(.startingTranscription)
        let start = try await client.startTranscription(recordingId: created.id, language: language)
        manifest.jobId = start.jobId
        manifest.stage = "startingTranscription"
        manifest = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)

        let job = try await pollForCompletion(
            client: client,
            recordingId: created.id,
            initial: start,
            updatePhase: updatePhase
        )

        manifest.provider = job.provider
        manifest.model = job.model
        manifest.transcriptId = job.transcriptId
        manifest.stage = "fetchingTranscript"
        manifest = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)

        updatePhase(.fetchingTranscript)
        let transcript = try await client.getTranscript(recordingId: created.id, jobId: job.id)
        try RecordingStore.saveTranscript(transcript.text, in: sessionDir)

        var insights: MeetingInsights?
        if UITestModeConfiguration.shared.summaryStubEnabled && !UITestModeConfiguration.shared.disableSummary {
            updatePhase(.summarizing)
            let extracted = Self.makeUITestStubInsights(from: transcript.text)
            try RecordingStore.saveSummary(extracted, in: sessionDir)
            try RecordingStore.saveActionItems(extracted.actionItems, in: sessionDir)
            insights = extracted
        } else if config.selectedProvider != .none && !UITestModeConfiguration.shared.disableSummary {
            updatePhase(.summarizing)
            let provider = createInsightsProvider(config: config)
            let extracted = try await provider.extract(transcript: transcript.text)
            try RecordingStore.saveSummary(extracted, in: sessionDir)
            try RecordingStore.saveActionItems(extracted.actionItems, in: sessionDir)
            insights = extracted
        }

        manifest.stage = "done"
        manifest.errorMessage = nil
        manifest.transcriptId = transcript.id
        _ = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)

        return RecordingResult(
            folderURL: sessionDir,
            transcript: transcript.text,
            duration: duration,
            insights: insights
        )
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

    private func cookieValue() throws -> String {
        guard let value = CookieSessionStore.shared.cookieValue() else {
            throw RecappiSessionError.notSignedIn
        }
        return value
    }

    nonisolated static func makeUITestStubInsights(from transcript: String) -> MeetingInsights {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = trimmed.isEmpty ? "Transcript unavailable." : String(trimmed.prefix(220))
        return MeetingInsights(
            summary: """
            ## Automation Summary

            This summary was generated by the UI-test stub path so Apple automation can validate the post-transcript UX without requiring a live summary provider.

            Transcript excerpt: \(clipped)
            """,
            keyDecisions: [
                "Remote transcript completed successfully.",
                "UI automation summary stub executed.",
            ],
            actionItems: [
                .init(owner: "Automation", text: "Verify summary.md exists after the run", due: nil),
                .init(owner: "Automation", text: "Verify action-items.md exists after the run", due: nil),
            ]
        )
    }
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
