import AppKit
import AVFoundation
import Foundation

@MainActor
extension CloudLibraryStore {
    func processSelectedRecording(
        _ action: CloudRecordingProcessingAction,
        onJobUpdate: (@MainActor @Sendable (TranscriptionJob) -> Void)? = nil
    ) async {
        await startTranscriptionForSelectedRecording(action, onJobUpdate: onJobUpdate)
    }

    func processRecording(
        id recordingID: String,
        _ action: CloudRecordingProcessingAction,
        onJobUpdate: (@MainActor @Sendable (TranscriptionJob) -> Void)? = nil
    ) async {
        let trimmedID = recordingID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }

        if let recording = recordings.first(where: { $0.id == trimmedID }) {
            select(recording)
        } else {
            do {
                let recording = try await runAuthorized { client in
                    try await client.getRecording(id: trimmedID)
                }
                replaceRecording(recording)
                recordings.sort { lhs, rhs in
                    (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
                }
                select(recording)
            } catch let error as RecappiAPIError where error == .unauthorized {
                apply(error: error)
                return
            } catch {
                DiagnosticsLog.error(
                    "cloud",
                    "process_recording.lookup.failed recordingID=\(trimmedID) \(DiagnosticsLog.errorSummary(error))"
                )
                transcriptErrorMessage = transcriptMessage(for: error)
                return
            }
        }

        await startTranscriptionForSelectedRecording(action, onJobUpdate: onJobUpdate)
    }

    func retranscribeSelectedRecording() async {
        await processSelectedRecording(.transcriptAndSummary)
    }

    func importAudioFileAndTranscribe(_ sourceURL: URL) async {
        guard activeRecordingProcessingAction == nil else { return }
        do {
            let prepared = try await prepareImportedAudioSession(from: sourceURL)
            guard let placeholder = SessionProcessor.localRecordingPlaceholder(
                sessionDir: prepared.sessionURL,
                duration: prepared.duration,
                status: .uploading
            ) else {
                throw SessionProcessorError.recordingAudioMissing
            }

            localSessionURLsByRecordingID[placeholder.id] = prepared.sessionURL
            upsertLocalProcessingRecording(placeholder)
            select(placeholder)
            await processLocalOnlySelectedRecording(placeholder, .transcriptAndSummary)
        } catch {
            DiagnosticsLog.error(
                "cloud",
                "audio_import.failed file=\(sourceURL.lastPathComponent) \(DiagnosticsLog.errorSummary(error))"
            )
            transcriptErrorMessage = transcriptMessage(for: error)
        }
    }

    func startTranscriptionForSelectedRecording(
        _ action: CloudRecordingProcessingAction,
        onJobUpdate: (@MainActor @Sendable (TranscriptionJob) -> Void)? = nil
    ) async {
        guard let recording = selectedRecording else { return }
        guard activeRecordingProcessingAction == nil else { return }
        if let limitMessage = retranscriptionLimitMessage {
            transcriptErrorMessage = limitMessage
            return
        }
        guard recording.allowsProcessingRequest(hasLocalSession: selectedLocalSessionURL != nil) else { return }

        if recording.isLocalOnlyRecording {
            await processLocalOnlySelectedRecording(recording, action)
            return
        }

        isRetranscribing = true
        activeRecordingProcessingAction = action
        setProcessingPhase(.startingTranscription, for: recording.id)
        transcriptErrorMessage = nil
        locallyManagedRecordingUpdatedAt[recording.id] = Date()
        hasNewerVersionForSelection = false
        recordingIDsWithNewerVersions.remove(recording.id)
        defer {
            isRetranscribing = false
            activeRecordingProcessingAction = nil
            setProcessingPhase(nil, for: recording.id)
        }

        do {
            let language = config.normalizedCloudLanguage
            let start = try await runAuthorized { client in
                try await client.startTranscription(
                    recordingId: recording.id,
                    language: language,
                    force: true,
                    provider: "gemini",
                    prompt: RecordingContextPrompt.text(
                        sceneRaw: config.recordingSceneTemplate,
                        extraPrompt: config.recordingExtraPrompt
                    )
                )
            }
            let job = try await runAuthorized { client in
                try await client.getJob(jobId: start.jobId)
            }
            upsertJob(job, for: recording.id)
            onJobUpdate?(job)
            if job.status == .succeeded {
                try await refreshTranscriptAfterJobSucceeded(recording: recording, job: job)
            } else if job.status.isActive {
                await pollActiveJobsUntilTerminal(
                    recordingID: recording.id,
                    jobIDs: [job.id],
                    onJobUpdate: onJobUpdate
                )
            }
            await persistCacheSnapshot()
        } catch let error as RecappiAPIError where error == .unauthorized {
            apply(error: error)
        } catch {
            DiagnosticsLog.error(
                "cloud",
                "transcription.start.failed recordingID=\(recording.id) action=\(action.rawValue) \(DiagnosticsLog.errorSummary(error))"
            )
            transcriptErrorMessage = transcriptMessage(for: error)
        }
    }

    private func processLocalOnlySelectedRecording(
        _ recording: CloudRecording,
        _ action: CloudRecordingProcessingAction
    ) async {
        guard let sessionURL = localSessionURLsByRecordingID[recording.id] else {
            transcriptErrorMessage = "This recording is saved locally, but its local audio folder is unavailable."
            return
        }

        isRetranscribing = true
        activeRecordingProcessingAction = action
        var visibleProcessingID = recording.id
        setProcessingPhase(.creatingRecording, for: visibleProcessingID)
        transcriptErrorMessage = nil
        locallyManagedRecordingUpdatedAt[recording.id] = Date()
        hasNewerVersionForSelection = false
        recordingIDsWithNewerVersions.remove(recording.id)
        defer {
            isRetranscribing = false
            activeRecordingProcessingAction = nil
            setProcessingPhase(nil, for: visibleProcessingID)
            if visibleProcessingID != recording.id {
                setProcessingPhase(nil, for: recording.id)
            }
        }

        let duration = localProcessingDurationSeconds(for: recording)
        if let placeholder = SessionProcessor.localRecordingPlaceholder(
            sessionDir: sessionURL,
            duration: duration,
            status: .uploading
        ) {
            upsertLocalProcessingRecording(placeholder)
        }

        do {
            _ = try await SessionProcessor.shared.process(
                sessionDir: sessionURL,
                duration: duration,
                startsTranscription: true,
                updatePhase: { phase in
                    self.setProcessingPhase(phase, for: visibleProcessingID)
                    DiagnosticsLog.event(
                        "cloud",
                        "local_processing.phase recordingID=\(recording.id) phase=\(phase.title)"
                    )
                },
                onCloudRecordingUpdated: { [weak self] updatedRecording, latestJob in
                    guard let self else { return }
                    let previousID = visibleProcessingID
                    visibleProcessingID = updatedRecording.id
                    self.upsertLocalProcessingRecording(
                        updatedRecording,
                        latestJob: latestJob,
                        replacing: recording.id
                    )
                    if previousID != visibleProcessingID,
                       let phase = self.processingPhasesByRecordingID.removeValue(forKey: previousID) {
                        self.processingPhasesByRecordingID[visibleProcessingID] = phase
                    }
                },
                onCloudRecordingDeleted: { [weak self] recordingID in
                    guard recordingID != recording.id else { return }
                    self?.removeLocalProcessingRecording(id: recordingID)
                }
            )

            await refreshLocalSessionLinks()
            if let remoteID = RecordingStore.loadRemoteManifest(in: sessionURL)?.recordingId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !remoteID.isEmpty,
               let remoteRecording = recordings.first(where: { $0.id == remoteID }) {
                select(remoteRecording)
                transcriptCache.removeValue(forKey: remoteID)
                transcriptCacheRecordingUpdatedAt.removeValue(forKey: remoteID)
                summaryRefreshAttemptedRecordingIDs.remove(remoteID)
                await loadTranscriptForSelection()
                await loadJobHistoryForSelection()
            }
            await persistCacheSnapshot()
        } catch let error as RecappiAPIError where error == .unauthorized {
            apply(error: error)
        } catch {
            DiagnosticsLog.error(
                "cloud",
                "local_processing.failed recordingID=\(recording.id) action=\(action.rawValue) \(DiagnosticsLog.errorSummary(error))"
            )
            let message = transcriptMessage(for: error)
            setProcessingPhase(nil, for: visibleProcessingID)
            if let placeholder = SessionProcessor.localFailedRecordingPlaceholder(
                sessionDir: sessionURL,
                duration: duration,
                error: error
            ) {
                upsertLocalProcessingRecording(
                    placeholder,
                    latestJob: TranscriptionJob.failedRecordingPlaceholder(
                        recordingID: placeholder.id,
                        error: message
                    )
                )
            }
            transcriptErrorMessage = message
        }
    }

    private func localProcessingDurationSeconds(for recording: CloudRecording) -> Int {
        guard let durationMs = recording.durationMs, durationMs > 0 else { return 0 }
        return Int((Double(durationMs) / 1_000).rounded(.up))
    }

    private func prepareImportedAudioSession(from sourceURL: URL) async throws -> (sessionURL: URL, duration: Int) {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard !fileExtension.isEmpty,
              SessionProcessor.cloudUploadContentType(for: sourceURL) != nil else {
            throw SessionProcessorError.unsupportedAudioFile(fileExtension.isEmpty ? "audio" : fileExtension)
        }

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sessionURL = try RecordingStore.createSessionDirectory()
        let destination = sessionURL.appendingPathComponent("recording.\(fileExtension)")
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        let title = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        RecordingStore.saveSessionMetadata(
            .capture(
                sourceTitle: title.isEmpty ? "Imported audio" : title,
                sourceAppName: "Imported Audio",
                sourceBundleID: nil,
                sceneTemplate: config.recordingSceneTemplate,
                extraPrompt: config.recordingExtraPrompt,
                includesMicrophoneAudio: false
            ),
            in: sessionURL
        )

        var manifest = RemoteSessionManifest.stage("imported")
        manifest.uploadFilename = destination.lastPathComponent
        if let account = cacheContext() {
            manifest.accountUserId = account.userId
            manifest.accountBackendOrigin = account.backendOrigin
        }
        RecordingStore.saveRemoteManifest(manifest, in: sessionURL)

        return (sessionURL, try await importedAudioDurationSeconds(for: destination))
    }

    private func importedAudioDurationSeconds(for fileURL: URL) async throws -> Int {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(seconds.rounded(.up))
    }

    var retranscriptionLimitMessage: String? {
        guard let billingStatus else { return nil }
        if billingStatus.effectiveIsOverMinutes {
            return "Cloud minutes limit reached. Upgrade your plan or free usage before retranscribing."
        }
        if billingStatus.effectiveIsOverStorage {
            return "Cloud storage limit reached. Delete recordings or upgrade before retranscribing."
        }
        return nil
    }


}
