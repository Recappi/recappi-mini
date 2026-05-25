import AppKit
import Foundation

@MainActor
extension CloudLibraryStore {
    func processSelectedRecording(_ action: CloudRecordingProcessingAction) async {
        await startTranscriptionForSelectedRecording(action)
    }

    func processRecording(id recordingID: String, _ action: CloudRecordingProcessingAction) async {
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

        await startTranscriptionForSelectedRecording(action)
    }

    func retranscribeSelectedRecording() async {
        await processSelectedRecording(.transcriptAndSummary)
    }

    func startTranscriptionForSelectedRecording(_ action: CloudRecordingProcessingAction) async {
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
        transcriptErrorMessage = nil
        locallyManagedRecordingUpdatedAt[recording.id] = Date()
        hasNewerVersionForSelection = false
        recordingIDsWithNewerVersions.remove(recording.id)
        defer {
            isRetranscribing = false
            activeRecordingProcessingAction = nil
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
            if job.status == .succeeded {
                try await refreshTranscriptAfterJobSucceeded(recording: recording, job: job)
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
        transcriptErrorMessage = nil
        locallyManagedRecordingUpdatedAt[recording.id] = Date()
        hasNewerVersionForSelection = false
        recordingIDsWithNewerVersions.remove(recording.id)
        defer {
            isRetranscribing = false
            activeRecordingProcessingAction = nil
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
                    DiagnosticsLog.event(
                        "cloud",
                        "local_processing.phase recordingID=\(recording.id) phase=\(phase.title)"
                    )
                },
                onCloudRecordingUpdated: { [weak self] updatedRecording, latestJob in
                    self?.upsertLocalProcessingRecording(updatedRecording, latestJob: latestJob)
                },
                onCloudRecordingDeleted: { [weak self] recordingID in
                    self?.removeLocalProcessingRecording(id: recordingID)
                }
            )

            await refreshLocalSessionLinks()
            if let remoteID = RecordingStore.loadRemoteManifest(in: sessionURL)?.recordingId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !remoteID.isEmpty,
               let remoteRecording = recordings.first(where: { $0.id == remoteID }) {
                select(remoteRecording)
            }
            await persistCacheSnapshot()
        } catch let error as RecappiAPIError where error == .unauthorized {
            apply(error: error)
        } catch {
            DiagnosticsLog.error(
                "cloud",
                "local_processing.failed recordingID=\(recording.id) action=\(action.rawValue) \(DiagnosticsLog.errorSummary(error))"
            )
            if let placeholder = SessionProcessor.localFailedRecordingPlaceholder(
                sessionDir: sessionURL,
                duration: duration,
                error: error
            ) {
                upsertLocalProcessingRecording(
                    placeholder,
                    latestJob: TranscriptionJob.failedRecordingPlaceholder(recordingID: placeholder.id)
                )
            }
            transcriptErrorMessage = transcriptMessage(for: error)
        }
    }

    private func localProcessingDurationSeconds(for recording: CloudRecording) -> Int {
        guard let durationMs = recording.durationMs, durationMs > 0 else { return 0 }
        return Int((Double(durationMs) / 1_000).rounded(.up))
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
