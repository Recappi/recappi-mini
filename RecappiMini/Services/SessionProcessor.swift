import Foundation

@MainActor
final class SessionProcessor {
    static let shared = SessionProcessor()
    private static let transcriptionPollingTimeout: TimeInterval = 15 * 60
    private var activeProcessesBySessionPath: [String: ActiveProcess] = [:]

    // Allocating a DateFormatter / ISO8601DateFormatter per call is one of the
    // more expensive small ops on Apple platforms. These parsing formatters are
    // reused by the `nonisolated static` helpers below. The ISO formatter still
    // needs an explicit escape hatch; `DateFormatter` is `Sendable` under this
    // toolchain, so the directory parser can be a plain `nonisolated static`.
    // Both are configured once and then only used for reads. Configuration is
    // identical to the previous per-call instances, so parsed results are
    // unchanged.
    private nonisolated(unsafe) static let startedAtFormatter = ISO8601DateFormatter()

    private nonisolated static let sessionDirectoryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()

    private init() {}

    func process(
        sessionDir: URL,
        duration: Int,
        startsTranscription: Bool = true,
        updatePhase: @escaping @MainActor @Sendable (ProcessingPhase) -> Void,
        onCloudRecordingUpdated: @escaping @MainActor @Sendable (CloudRecording, TranscriptionJob?) -> Void = { _, _ in },
        onCloudRecordingDeleted: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> RecordingResult {
        let sessionKey = Self.sessionProcessingKey(for: sessionDir)
        if let active = activeProcessesBySessionPath[sessionKey] {
            DiagnosticsLog.warning(
                "processing",
                "process.coalesced_duplicate dir=\(sessionDir.lastPathComponent)"
            )
            return try await active.task.value
        }

        let processID = UUID()
        let task = Task { @MainActor in
            try await self.performProcess(
                sessionDir: sessionDir,
                duration: duration,
                startsTranscription: startsTranscription,
                updatePhase: updatePhase,
                onCloudRecordingUpdated: onCloudRecordingUpdated,
                onCloudRecordingDeleted: onCloudRecordingDeleted
            )
        }
        activeProcessesBySessionPath[sessionKey] = ActiveProcess(id: processID, task: task)
        do {
            let result = try await task.value
            if activeProcessesBySessionPath[sessionKey]?.id == processID {
                activeProcessesBySessionPath.removeValue(forKey: sessionKey)
            }
            return result
        } catch {
            if activeProcessesBySessionPath[sessionKey]?.id == processID {
                activeProcessesBySessionPath.removeValue(forKey: sessionKey)
            }
            throw error
        }
    }

    private func performProcess(
        sessionDir: URL,
        duration: Int,
        startsTranscription: Bool,
        updatePhase: @escaping @MainActor @Sendable (ProcessingPhase) -> Void,
        onCloudRecordingUpdated: @escaping @MainActor @Sendable (CloudRecording, TranscriptionJob?) -> Void,
        onCloudRecordingDeleted: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> RecordingResult {
        let origin = AppConfig.shared.effectiveBackendBaseURL
        var attemptedReauthentication = false
        DiagnosticsLog.event(
            "processing",
            "process.start dir=\(sessionDir.lastPathComponent) duration=\(duration) originHash=\(origin.hashValue)"
        )

        while true {
            do {
                let result = try await processOnce(
                    sessionDir: sessionDir,
                    duration: duration,
                    startsTranscription: startsTranscription,
                    updatePhase: updatePhase,
                    onCloudRecordingUpdated: onCloudRecordingUpdated,
                    onCloudRecordingDeleted: onCloudRecordingDeleted
                )
                DiagnosticsLog.event("processing", "process.succeeded dir=\(sessionDir.lastPathComponent)")
                return result
            } catch let error as RecappiAPIError where error == .unauthorized && !attemptedReauthentication {
                attemptedReauthentication = true
                DiagnosticsLog.warning("processing", "process.unauthorized_reauth dir=\(sessionDir.lastPathComponent)")
                updatePhase(.verifyingSession)
                _ = try await AuthSessionStore.shared.handleUnauthorized(origin: origin)
            } catch let failure as UploadFailure {
                DiagnosticsLog.warning(
                    "processing",
                    "process.upload_failed dir=\(sessionDir.lastPathComponent) \(DiagnosticsLog.errorSummary(failure.error))"
                )
                throw failure.error
            } catch {
                DiagnosticsLog.error(
                    "processing",
                    "process.failed dir=\(sessionDir.lastPathComponent) \(DiagnosticsLog.errorSummary(error))"
                )
                throw error
            }
        }
    }

    nonisolated static func sessionProcessingKey(for sessionDir: URL) -> String {
        sessionDir.standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated static func localRecordingID(for sessionDir: URL) -> String {
        "local-\(sessionDir.lastPathComponent)"
    }

    nonisolated static func localRecordingPlaceholder(
        sessionDir: URL,
        duration: Int,
        status: CloudRecordingStatus
    ) -> CloudRecording? {
        let manifest = RecordingStore.loadRemoteManifest(in: sessionDir)
        guard let audioURL = primaryAudioFileURL(in: sessionDir, manifest: manifest) else {
            return nil
        }
        guard (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)?
            .int64Value ?? 0 > 0 else {
            return nil
        }

        let metadata = RecordingStore.loadSessionMetadata(in: sessionDir)
        return CloudRecording(
            id: localRecordingID(for: sessionDir),
            userId: nil,
            title: metadata?.cloudRecordingTitle ?? sessionDir.lastPathComponent,
            summaryTitle: metadata?.summaryTitle,
            sourceTitle: metadata?.sourceTitle,
            sourceAppName: metadata?.sourceAppName,
            sourceAppBundleID: metadata?.sourceBundleID,
            r2Key: nil,
            r2UploadId: nil,
            status: status,
            sizeBytes: Self.fileSize(audioURL),
            durationMs: duration > 0 ? duration * 1000 : nil,
            sampleRate: nil,
            channels: nil,
            contentType: Self.cloudUploadContentType(for: audioURL),
            activeTranscriptId: nil,
            createdAt: localRecordingCreatedAt(sessionDir: sessionDir, metadata: metadata, audioURL: audioURL),
            updatedAt: Date()
        )
    }

    nonisolated static func localFailedRecordingPlaceholder(
        sessionDir: URL,
        duration: Int,
        error _: Error
    ) -> CloudRecording? {
        localRecordingPlaceholder(
            sessionDir: sessionDir,
            duration: duration,
            status: .failed
        )
    }

    private func processOnce(
        sessionDir: URL,
        duration: Int,
        startsTranscription: Bool,
        updatePhase: @escaping @MainActor @Sendable (ProcessingPhase) -> Void,
        onCloudRecordingUpdated: @escaping @MainActor @Sendable (CloudRecording, TranscriptionJob?) -> Void,
        onCloudRecordingDeleted: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> RecordingResult {
        let config = AppConfig.shared
        guard config.cloudEnabled else {
            throw SessionProcessorError.cloudDisabled
        }

        updatePhase(.verifyingSession)
        DiagnosticsLog.event("processing", "auth.verify.start dir=\(sessionDir.lastPathComponent)")
        let session = try await AuthSessionStore.shared.ensureAuthorized(origin: config.effectiveBackendBaseURL)
        DiagnosticsLog.event("processing", "auth.verify.succeeded dir=\(sessionDir.lastPathComponent) originHash=\(session.backendOrigin.hashValue)")
        let client = RecappiAPIClient(origin: session.backendOrigin, bearerToken: try bearerToken())

        var manifest = RecordingStore.loadRemoteManifest(in: sessionDir) ?? .stage("verifyingSession")
        manifest = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)
        DiagnosticsLog.event(
            "processing",
            "manifest.loaded dir=\(sessionDir.lastPathComponent) stage=\(manifest.stage) recording=\(manifest.recordingId ?? "none") job=\(manifest.jobId ?? "none") transcript=\(manifest.transcriptId ?? "none")"
        )
        if manifest.stage == "done",
           let transcript = RecordingStore.loadTranscript(in: sessionDir) {
            DiagnosticsLog.event("processing", "manifest.done_reuse dir=\(sessionDir.lastPathComponent)")
            return RecordingResult(
                folderURL: sessionDir,
                transcript: transcript,
                duration: duration
            )
        }
        let recordingURL = Self.primaryAudioFileURL(in: sessionDir, manifest: manifest)
            ?? RecordingStore.audioFileURL(in: sessionDir)

        let uploadedRecording: UploadedRecordingAsset
        if let recordingId = Self.reusableRecordingID(in: manifest) {
            DiagnosticsLog.event(
                "processing",
                "recording.reuse dir=\(sessionDir.lastPathComponent) recording=\(recordingId) stage=\(manifest.stage)"
            )
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
                onCloudRecordingUpdated: onCloudRecordingUpdated,
                onCloudRecordingDeleted: onCloudRecordingDeleted
            )
        }
        manifest = uploadedRecording.manifest

        guard startsTranscription else {
            manifest.stage = "synced"
            manifest.errorMessage = nil
            manifest.jobId = nil
            manifest.transcriptId = nil
            _ = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)
            await refreshServerRecordingState(
                client: client,
                recordingID: uploadedRecording.recordingId,
                latestJob: nil,
                onCloudRecordingUpdated: onCloudRecordingUpdated
            )
            DiagnosticsLog.event(
                "processing",
                "transcription.deferred recording=\(uploadedRecording.recordingId) scene=\(RecordingStore.loadSessionMetadata(in: sessionDir)?.sceneTemplate ?? "none")"
            )
            return RecordingResult(
                folderURL: sessionDir,
                transcript: nil,
                duration: duration
            )
        }

        if Self.reusableTranscriptID(in: manifest) != nil {
            updatePhase(.fetchingTranscript)
            DiagnosticsLog.event(
                "processing",
                "transcript.fetch.reuse recording=\(uploadedRecording.recordingId) transcript=\(manifest.transcriptId ?? "none")"
            )
            let transcript = try await client.getRecordingTranscript(id: uploadedRecording.recordingId)
            try RecordingStore.saveTranscriptArtifacts(transcript, in: sessionDir)
            manifest.stage = "done"
            manifest.errorMessage = nil
            manifest.transcriptId = transcript.id
            _ = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)
            await refreshServerRecordingState(
                client: client,
                recordingID: uploadedRecording.recordingId,
                latestJob: nil,
                onCloudRecordingUpdated: onCloudRecordingUpdated
            )
            return RecordingResult(
                folderURL: sessionDir,
                transcript: transcript.text,
                duration: duration
            )
        }

        let language = config.normalizedCloudLanguage
        let start: StartTranscriptionResponse
        if let jobId = Self.reusableJobID(in: manifest) {
            DiagnosticsLog.event("processing", "transcription.job.reuse recording=\(uploadedRecording.recordingId) job=\(jobId)")
            start = StartTranscriptionResponse(
                jobId: jobId,
                status: .queued,
                transcriptId: manifest.transcriptId
            )
        } else {
            updatePhase(.startingTranscription)
            DiagnosticsLog.event(
                "processing",
                "transcription.start recording=\(uploadedRecording.recordingId) language=\(language)"
            )
            let metadata = RecordingStore.loadSessionMetadata(in: sessionDir)
            start = try await client.startTranscription(
                recordingId: uploadedRecording.recordingId,
                language: language,
                prompt: RecordingContextPrompt.text(from: metadata)
            )
            DiagnosticsLog.event(
                "processing",
                "transcription.started recording=\(uploadedRecording.recordingId) job=\(start.jobId) status=\(start.status.rawValue)"
            )
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
            DiagnosticsLog.error(
                "processing",
                "transcription.poll.failed recording=\(uploadedRecording.recordingId) job=\(start.jobId) \(DiagnosticsLog.errorSummary(error))"
            )
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
        DiagnosticsLog.event(
            "processing",
            "transcript.fetch.start recording=\(uploadedRecording.recordingId) job=\(job.id)"
        )
        let transcript = try await client.getTranscript(recordingId: uploadedRecording.recordingId, jobId: job.id)
        DiagnosticsLog.event(
            "processing",
            "transcript.fetch.succeeded recording=\(uploadedRecording.recordingId) job=\(job.id) transcript=\(transcript.id) chars=\(transcript.text.count)"
        )
        try RecordingStore.saveTranscriptArtifacts(transcript, in: sessionDir)

        manifest.stage = "done"
        manifest.errorMessage = nil
        manifest.transcriptId = transcript.id
        _ = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)
        await refreshServerRecordingState(
            client: client,
            recordingID: uploadedRecording.recordingId,
            latestJob: job,
            onCloudRecordingUpdated: onCloudRecordingUpdated
        )

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
        onCloudRecordingUpdated: @escaping @MainActor @Sendable (CloudRecording, TranscriptionJob?) -> Void,
        onCloudRecordingDeleted: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> UploadedRecordingAsset {
        try Self.validatePrimaryRecordingForUpload(primaryURL)

        let uploadAsset: UploadAudioAsset
        if let contentType = Self.cloudUploadContentType(for: primaryURL) {
            uploadAsset = UploadAudioAsset(
                url: primaryURL,
                contentType: contentType,
                durationMs: Self.uploadDurationMs(fromSeconds: duration)
            )
            DiagnosticsLog.event(
                "processing",
                "upload.asset.primary file=\(primaryURL.lastPathComponent) size=\(Self.fileSize(primaryURL)) contentType=\(contentType) durationMs=\(uploadAsset.durationMs)"
            )
        } else {
            updatePhase(.preparingUploadWav)
            DiagnosticsLog.event(
                "processing",
                "upload.asset.export_wav.start file=\(primaryURL.lastPathComponent) size=\(Self.fileSize(primaryURL))"
            )
            let uploadURL = try await UploadAudioExporter.ensureUploadAudio(for: sessionDir)
            uploadAsset = UploadAudioAsset(
                url: uploadURL,
                contentType: "audio/wav",
                durationMs: Self.uploadDurationMs(fromSeconds: duration)
            )
            DiagnosticsLog.event(
                "processing",
                "upload.asset.export_wav.succeeded file=\(uploadURL.lastPathComponent) size=\(Self.fileSize(uploadURL)) durationMs=\(uploadAsset.durationMs)"
            )
        }

        do {
            return try await uploadAndComplete(
                uploadAsset: uploadAsset,
                client: client,
                manifest: manifest,
                duration: duration,
                updatePhase: updatePhase,
                onCloudRecordingUpdated: onCloudRecordingUpdated,
                onCloudRecordingDeleted: onCloudRecordingDeleted
            )
        } catch {
            let failure = Self.unwrapUploadAttemptFailure(error)
            if let abandonedRecordingID = failure.abandonedRecordingID,
               await deleteAbandonedRecordingIfPossible(abandonedRecordingID, client: client) {
                onCloudRecordingDeleted(abandonedRecordingID)
            }
            DiagnosticsLog.error(
                "processing",
                "upload.failed file=\(uploadAsset.url.lastPathComponent) recording=\(failure.abandonedRecordingID ?? "none") \(DiagnosticsLog.errorSummary(failure.error))"
            )
            var failedManifest = manifest
            failedManifest.uploadFilename = uploadAsset.url.lastPathComponent
            failedManifest.errorMessage = failure.error.localizedDescription
            failedManifest.stage = "uploadFailed"
            _ = RecordingStore.saveRemoteManifest(failedManifest, in: sessionDir)
            throw UploadFailure(error: failure.error)
        }
    }

    private func uploadAndComplete(
        uploadAsset: UploadAudioAsset,
        client: RecappiAPIClient,
        manifest: RemoteSessionManifest,
        duration: Int,
        updatePhase: @escaping @MainActor @Sendable (ProcessingPhase) -> Void,
        onCloudRecordingUpdated: @escaping @MainActor @Sendable (CloudRecording, TranscriptionJob?) -> Void,
        onCloudRecordingDeleted: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> UploadedRecordingAsset {
        let fileURL = uploadAsset.url
        var nextManifest = manifest
        nextManifest.uploadFilename = fileURL.lastPathComponent
        nextManifest.errorMessage = nil
        nextManifest = RecordingStore.saveRemoteManifest(nextManifest, in: fileURL.deletingLastPathComponent())

        updatePhase(.creatingRecording)
        let sessionDir = fileURL.deletingLastPathComponent()
        let recordingTitle = RecordingStore.loadSessionMetadata(in: sessionDir)?.cloudRecordingTitle
            ?? sessionDir.lastPathComponent
        DiagnosticsLog.event(
            "processing",
            "recording.create.start file=\(fileURL.lastPathComponent) contentType=\(uploadAsset.contentType) durationMs=\(uploadAsset.durationMs) size=\(Self.fileSize(fileURL))"
        )
        let created = try await client.createRecording(
            title: recordingTitle,
            contentType: uploadAsset.contentType,
            durationMs: uploadAsset.durationMs
        )
        DiagnosticsLog.event(
            "processing",
            "recording.create.succeeded recording=\(created.id) partSize=\(created.partSize) r2KeyPresent=\(!created.r2Key.isEmpty)"
        )
        nextManifest.recordingId = created.id
        nextManifest.jobId = nil
        nextManifest.transcriptId = nil
        nextManifest.stage = "creatingRecording"
        nextManifest = RecordingStore.saveRemoteManifest(nextManifest, in: fileURL.deletingLastPathComponent())
        onCloudRecordingDeleted(Self.localRecordingID(for: sessionDir))
        var localRecording = Self.localCloudRecording(
            id: created.id,
            title: recordingTitle,
            r2Key: created.r2Key,
            status: .uploading,
            duration: duration,
            contentType: uploadAsset.contentType,
            sessionDir: sessionDir
        )
        onCloudRecordingUpdated(localRecording, nil)

        do {
            updatePhase(.uploading(progress: 0))
            DiagnosticsLog.event(
                "processing",
                "upload.start recording=\(created.id) file=\(fileURL.lastPathComponent) size=\(Self.fileSize(fileURL)) partSize=\(created.partSize)"
            )
            let parts = try await client.uploadRecording(
                recordingId: created.id,
                fileURL: fileURL,
                partSize: created.partSize
            ) { progress in
                updatePhase(.uploading(progress: progress))
            }
            DiagnosticsLog.event(
                "processing",
                "upload.parts.succeeded recording=\(created.id) partCount=\(parts.count)"
            )

            updatePhase(.completingUpload)
            DiagnosticsLog.event("processing", "upload.complete.start recording=\(created.id) partCount=\(parts.count)")
            let completed = try await client.completeRecording(recordingId: created.id, parts: parts)
            DiagnosticsLog.event(
                "processing",
                "upload.complete.succeeded recording=\(created.id) status=\(completed.status) contentType=\(completed.contentType)"
            )
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
            DiagnosticsLog.error(
                "processing",
                "upload.attempt.failed recording=\(created.id) \(DiagnosticsLog.errorSummary(error))"
            )
            await client.abortRecordingIfNeeded(recordingId: created.id)
            throw UploadAttemptFailure(error: error, abandonedRecordingID: created.id)
        }
    }

    nonisolated static func validatePrimaryRecordingForUpload(_ fileURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path),
              Self.fileSize(fileURL) > 0 else {
            throw SessionProcessorError.recordingAudioMissing
        }
    }

    nonisolated static func primaryAudioFileURL(
        in sessionDir: URL,
        manifest: RemoteSessionManifest? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        if let uploadFilename = manifest?.uploadFilename?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !uploadFilename.isEmpty {
            let manifestURL = sessionDir.appendingPathComponent(uploadFilename)
            if fileManager.fileExists(atPath: manifestURL.path) {
                return manifestURL
            }
        }

        let candidates = [
            RecordingStore.audioFileURL(in: sessionDir),
            sessionDir.appendingPathComponent("recording.wav"),
            sessionDir.appendingPathComponent("recording.mp3"),
            sessionDir.appendingPathComponent("recording.aac"),
            sessionDir.appendingPathComponent("recording.m4a"),
            sessionDir.appendingPathComponent("recording.flac"),
            sessionDir.appendingPathComponent("recording.ogg"),
            sessionDir.appendingPathComponent("recording.aiff"),
            sessionDir.appendingPathComponent("recording.aif"),
            RecordingStore.uploadAudioFileURL(in: sessionDir),
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    nonisolated static func cloudUploadContentType(for fileURL: URL) -> String? {
        switch fileURL.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mp3"
        case "aif", "aiff":
            return "audio/aiff"
        case "aac":
            return "audio/aac"
        case "m4a":
            // Recappi records AAC-only `.m4a` artifacts. The backend's
            // current non-WAV allow-list canonicalizes AAC as `audio/aac`.
            return "audio/aac"
        case "ogg":
            return "audio/ogg"
        case "flac":
            return "audio/flac"
        default:
            return nil
        }
    }

    private nonisolated static func uploadDurationMs(fromSeconds duration: Int) -> Int {
        max(1, duration) * 1000
    }

    private nonisolated static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? -1
    }

    private func deleteAbandonedRecordingIfPossible(_ recordingID: String, client: RecappiAPIClient) async -> Bool {
        do {
            try await client.deleteRecording(id: recordingID)
            return true
        } catch RecappiAPIError.http(let statusCode, _) where statusCode == 404 {
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func unwrapUploadAttemptFailure(_ error: Error) -> (error: Error, abandonedRecordingID: String?) {
        if let failure = error as? UploadAttemptFailure {
            return (failure.error, failure.abandonedRecordingID)
        }
        return (error, nil)
    }

    private func pollForCompletion(
        client: RecappiAPIClient,
        recordingId: String,
        initial: StartTranscriptionResponse,
        updatePhase: @escaping @MainActor @Sendable (ProcessingPhase) -> Void,
        onJobUpdate: @escaping @MainActor @Sendable (TranscriptionJob) -> Void
    ) async throws -> TranscriptionJob {
        if initial.status == .succeeded {
            DiagnosticsLog.event("processing", "transcription.poll.initial_succeeded job=\(initial.jobId)")
            let job = try await client.getJob(jobId: initial.jobId)
            onJobUpdate(job)
            return job
        }

        let startedPollingAt = Date()
        var lastLongPollWarningAt: Date?
        while true {
            let job = try await client.getJob(jobId: initial.jobId)
            onJobUpdate(job)
            updatePhase(.polling(jobStatus: job.status.rawValue))
            DiagnosticsLog.event(
                "processing",
                "transcription.poll job=\(job.id) status=\(job.status.rawValue) transcript=\(job.transcriptId ?? "none") attempts=\(job.attempts ?? -1)"
            )
            switch job.status {
            case .queued, .running:
                let elapsed = Date().timeIntervalSince(startedPollingAt)
                if elapsed >= Self.transcriptionPollingTimeout {
                    DiagnosticsLog.warning(
                        "processing",
                        "transcription.poll.timeout job=\(job.id) status=\(job.status.rawValue) elapsed=\(Int(elapsed))"
                    )
                    throw SessionProcessorError.jobTimedOut
                }
                if lastLongPollWarningAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? (elapsed >= 60) {
                    lastLongPollWarningAt = Date()
                    DiagnosticsLog.warning(
                        "processing",
                        "transcription.poll.still_waiting job=\(job.id) status=\(job.status.rawValue) elapsed=\(Int(elapsed))"
                    )
                }
                try await Task.sleep(for: .seconds(2))
            case .succeeded:
                return job
            case .failed:
                throw SessionProcessorError.jobFailed(job.error ?? "Transcription failed")
            }
        }
    }

    private func refreshServerRecordingState(
        client: RecappiAPIClient,
        recordingID: String,
        latestJob: TranscriptionJob?,
        onCloudRecordingUpdated: @escaping @MainActor @Sendable (CloudRecording, TranscriptionJob?) -> Void
    ) async {
        DiagnosticsLog.event("processing", "recording.detail.refresh.start recording=\(recordingID)")
        do {
            let recording = try await client.getRecording(id: recordingID)
            onCloudRecordingUpdated(recording, latestJob)
            DiagnosticsLog.event(
                "processing",
                "recording.detail.refresh.succeeded recording=\(recordingID) activeTranscript=\(recording.activeTranscriptId ?? "none")"
            )
        } catch {
            // The transcript is already saved locally at this point. A detail
            // refresh failure should not turn a successful recording into a
            // failed one; the Cloud panel can still refresh the detail later.
            DiagnosticsLog.warning(
                "processing",
                "recording.detail.refresh.failed recording=\(recordingID) \(DiagnosticsLog.errorSummary(error))"
            )
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
            createdAt: localRecordingCreatedAt(sessionDir: sessionDir, metadata: metadata),
            updatedAt: Date()
        )
    }

    private nonisolated static func localRecordingCreatedAt(
        sessionDir: URL,
        metadata: RecordingSessionMetadata?,
        audioURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> Date {
        if let startedAt = metadata?.startedAt,
           let date = startedAtFormatter.date(from: startedAt) {
            return date
        }

        if let date = sessionDirectoryDate(from: sessionDir.lastPathComponent) {
            return date
        }

        if let audioURL,
           let attributes = try? fileManager.attributesOfItem(atPath: audioURL.path) {
            if let creationDate = attributes[.creationDate] as? Date {
                return creationDate
            }
            if let modificationDate = attributes[.modificationDate] as? Date {
                return modificationDate
            }
        }

        return Date()
    }

    private nonisolated static func sessionDirectoryDate(from name: String) -> Date? {
        sessionDirectoryDateFormatter.date(from: name)
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

private struct UploadAudioAsset {
    let url: URL
    let contentType: String
    let durationMs: Int
}

private struct ActiveProcess {
    let id: UUID
    let task: Task<RecordingResult, Error>
}

private struct UploadedRecordingAsset {
    let recordingId: String
    let recording: CloudRecording
    let manifest: RemoteSessionManifest
}

private struct UploadAttemptFailure: Error {
    let error: Error
    let abandonedRecordingID: String?
}

private struct UploadFailure: Error {
    let error: Error
}

enum SessionProcessorError: LocalizedError {
    case cloudDisabled
    case jobFailed(String)
    case jobTimedOut
    case recordingAudioMissing
    case unsupportedAudioFile(String)

    var errorDescription: String? {
        switch self {
        case .cloudDisabled:
            return "Recappi Cloud is disabled in Settings."
        case .jobFailed(let error):
            return "Recappi transcription failed: \(error)"
        case .jobTimedOut:
            return "转写仍在后台处理中，请稍后刷新云端记录"
        case .recordingAudioMissing:
            return "Recorded audio is missing or empty before upload: recording.m4a was not created for this session. This usually means no system or microphone audio was captured, or the meeting app was closed before stopping."
        case .unsupportedAudioFile(let fileExtension):
            return "Recappi cannot upload .\(fileExtension) audio yet. Choose an m4a, mp3, wav, aiff, aac, flac, or ogg file."
        }
    }
}
