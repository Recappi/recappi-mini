import AppKit
import Foundation

@MainActor
extension CloudLibraryStore {
    func processSelectedRecording(_ action: CloudRecordingProcessingAction) async {
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
                    provider: "gemini"
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
