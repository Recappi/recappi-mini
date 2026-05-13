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
        guard let recording = selectedRecording, recording.status.allowsTranscriptionRequest else { return }
        guard activeRecordingProcessingAction == nil else { return }
        if let limitMessage = retranscriptionLimitMessage {
            transcriptErrorMessage = limitMessage
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
            transcriptErrorMessage = transcriptMessage(for: error)
        }
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
