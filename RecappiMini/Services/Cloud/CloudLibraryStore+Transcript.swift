import AppKit
import Foundation

@MainActor
extension CloudLibraryStore {
    func loadJobHistoryForSelection() async {
        guard let recording = selectedRecording else { return }
        setJobHistoryLoading(true, for: recording.id)

        do {
            let page = try await runAuthorized { client in
                try await client.listRecordingJobs(recordingId: recording.id, limit: 50)
            }
            transcriptionJobsByRecordingID[recording.id] = page.items
            cacheWarningMessage = nil
            await persistCacheSnapshot()
        } catch let error as RecappiAPIError where error == .unauthorized {
            apply(error: error)
        } catch RecappiAPIError.http(let statusCode, _) where statusCode == 404 {
            // Older backend deployments do not expose recording job history yet.
            // Jobs started from this app are still tracked via POST /transcribe
            // + GET /api/jobs/:id.
            transcriptionJobsByRecordingID[recording.id] = transcriptionJobsByRecordingID[recording.id] ?? []
        } catch {
            if selectedRecordingID == recording.id {
                cacheWarningMessage = "Showing cached data · Job status refresh failed"
                isShowingCachedData = true
            }
        }

        setJobHistoryLoading(false, for: recording.id)
    }

    func pollSelectedActiveJobsUntilTerminal() async {
        while !Task.isCancelled {
            guard let recording = selectedRecording else { return }
            let activeJobs = (transcriptionJobsByRecordingID[recording.id] ?? [])
                .filter { $0.status.isActive }
            guard !activeJobs.isEmpty else { return }

            await refreshJobs(recordingID: recording.id, jobIDs: activeJobs.map(\.id))
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func loadTranscriptForSelection() async {
        guard let recording = selectedRecording else { return }
        // Shape-based fallback: when the cache holds a transcript with no
        // summary content but the recording itself is in a state where the
        // backend should have produced one by now, the cache is almost
        // certainly a pre-summarize snapshot that we never refreshed. Drop
        // it once per session so the load below actually fetches the
        // current body. The snapshot strategy in
        // `refreshSelectedDetailIfNeeded` is the primary path; this fallback
        // catches recordings that pre-date the snapshot dictionary (i.e.
        // came from older `CloudLibrarySnapshot` versions where the
        // `transcriptCacheRecordingUpdatedAt` map is empty), and any
        // recording whose `updatedAt` did not advance after summarize.
        if let cached = transcriptCache[recording.id],
           Self.shouldDropForMissingSummary(
               cachedTranscript: cached,
               recordingStatus: recording.status,
               alreadyAttempted: summaryRefreshAttemptedRecordingIDs.contains(recording.id)
           ) {
            transcriptCache.removeValue(forKey: recording.id)
            transcriptCacheRecordingUpdatedAt.removeValue(forKey: recording.id)
            summaryRefreshAttemptedRecordingIDs.insert(recording.id)
        }
        guard transcriptCache[recording.id] == nil else { return }
        // Capture the id we are loading for. The user may switch recordings
        // mid-flight; SwiftUI's `.task(id:)` already cancels the wrapping
        // Task, but we still rely on this captured id to avoid touching
        // unrelated state when the response (success or error) finally
        // resolves on a now-stale task. Network requests are intentionally
        // not allowed to block selection transitions — when this task is
        // cancelled, we silently bail.
        let loadingRecordingID = recording.id
        // Capture the recording-level `updatedAt` *before* the network call.
        // This becomes the freshness anchor stored alongside the transcript:
        // future detail refreshes will compare their freshly fetched
        // `recording.updatedAt` against this snapshot, not against whatever
        // value `recordings[id].updatedAt` has been overwritten to in the
        // meantime by `listRecordings()`.
        let recordingUpdatedAtSnapshot = recording.updatedAt
        setTranscriptLoading(true, for: loadingRecordingID)
        if selectedRecordingID == loadingRecordingID {
            transcriptErrorMessage = nil
        }

        PerfLog.start("loadTranscript")
        do {
            let transcript = try await runAuthorized { client in
                // `activeTranscriptId` identifies the transcript row, while the
                // backend's optional query parameter is a transcription job id.
                // Cloud Library wants the latest transcript for the recording.
                try await client.getRecordingTranscript(id: loadingRecordingID)
            }
            // Bail without state mutation if our load was cancelled while the
            // network call was in flight (e.g., user switched recordings).
            // The keyed-by-id writes below would technically be safe, but we
            // skip them to keep the response of a stale request from leaking
            // any side effect.
            try Task.checkCancellation()
            transcriptCache[loadingRecordingID] = transcript
            applySummaryTitleFromTranscript(transcript, to: loadingRecordingID)
            try? syncTranscriptToLocalSessionIfLinked(recording: recording, transcript: transcript)
            clearNewerVersionFlagIfCurrent(recordingID: loadingRecordingID, transcript: transcript)
            if let recordingUpdatedAtSnapshot {
                transcriptCacheRecordingUpdatedAt[loadingRecordingID] = recordingUpdatedAtSnapshot
            } else {
                // The recording row had no `updatedAt` when we cached the
                // transcript. Clear any prior snapshot so we don't leave a
                // stale anchor — the shape-based fallback above will be the
                // safety net for these recordings.
                transcriptCacheRecordingUpdatedAt.removeValue(forKey: loadingRecordingID)
            }
            // The transcript we just received now contains a summary if the
            // backend has produced one — successive selections of this
            // recording can stop probing via the shape-based fallback.
            if transcript.summary != nil
                || (transcript.summaryInsights?.isEmpty == false) {
                summaryRefreshAttemptedRecordingIDs.remove(loadingRecordingID)
            }
            PerfLog.end("loadTranscript", extra: "segments=\(transcript.segments.count)")
            await persistCacheSnapshot()
        } catch is CancellationError {
            PerfLog.end("loadTranscript", extra: "result=cancelled")
            // Don't touch loading flag through guarded path: still let the
            // `setTranscriptLoading(false, …)` below clear the keyed entry.
        } catch let error as RecappiAPIError where error == .unauthorized {
            PerfLog.end("loadTranscript", extra: "result=unauthorized")
            apply(error: error)
        } catch {
            PerfLog.end("loadTranscript", extra: "result=error type=\(String(describing: type(of: error)))")
            if selectedRecordingID == loadingRecordingID {
                transcriptErrorMessage = transcriptMessage(for: error)
            }
        }

        setTranscriptLoading(false, for: loadingRecordingID)
    }

    /// Pure decision for "the cached transcript looks like a pre-summarize
    /// snapshot, force one refetch to pick up the missing summary".
    ///
    /// Triggers when:
    /// - we already cached a transcript body (so the empty-cache path won't
    ///   re-fetch on its own), AND
    /// - that body has no `summary` text and no non-empty `summaryInsights`,
    ///   AND
    /// - the recording row is `.ready` (a state in which the backend would
    ///   normally have produced a summary), AND
    /// - we have not already attempted a force-refetch for this id this
    ///   session (avoids hammering recordings that genuinely have no
    ///   summary yet).
    nonisolated static func shouldDropForMissingSummary(
        cachedTranscript: TranscriptResponse,
        recordingStatus: CloudRecordingStatus,
        alreadyAttempted: Bool
    ) -> Bool {
        guard !alreadyAttempted else { return false }
        guard recordingStatus == .ready else { return false }
        let hasSummaryText = (cachedTranscript.summary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false)
        let hasSummaryInsights = cachedTranscript.summaryInsights?.isEmpty == false
        return !hasSummaryText && !hasSummaryInsights
    }


    func refreshJobs(recordingID: String, jobIDs: [String]) async {
        var didUpdateJobs = false
        for jobID in jobIDs {
            guard !Task.isCancelled else { return }
            do {
                let previousStatus = transcriptionJobsByRecordingID[recordingID]?
                    .first(where: { $0.id == jobID })?
                    .status
                let job = try await runAuthorized { client in
                    try await client.getJob(jobId: jobID)
                }
                upsertJob(job, for: recordingID)
                didUpdateJobs = true
                if previousStatus != .succeeded, job.status == .succeeded,
                   let recording = recordings.first(where: { $0.id == recordingID }) {
                    try await refreshTranscriptAfterJobSucceeded(recording: recording, job: job)
                }
            } catch let error as RecappiAPIError where error == .unauthorized {
                apply(error: error)
                return
            } catch {
                cacheWarningMessage = "Showing cached data · Job status refresh failed"
                isShowingCachedData = true
            }
        }
        if didUpdateJobs {
            await persistCacheSnapshot()
        }
    }

    func upsertJob(_ job: TranscriptionJob, for recordingID: String) {
        var jobs = transcriptionJobsByRecordingID[recordingID] ?? []
        jobs.removeAll { $0.id == job.id }
        jobs.insert(job, at: 0)
        jobs.sort { ($0.enqueuedAt ?? 0) > ($1.enqueuedAt ?? 0) }
        transcriptionJobsByRecordingID[recordingID] = Array(jobs.prefix(10))
    }

    func seedFailedRecordingJobPlaceholdersIfNeeded() {
        let failedRecordingIDs = Set(recordings.filter { $0.status == .failed }.map(\.id))
        let visibleRecordingIDs = Set(recordings.map(\.id))

        for recordingID in failedRecordingIDs where transcriptionJobsByRecordingID[recordingID]?.isEmpty != false {
            transcriptionJobsByRecordingID[recordingID] = [
                TranscriptionJob.failedRecordingPlaceholder(recordingID: recordingID)
            ]
        }

        for (recordingID, jobs) in transcriptionJobsByRecordingID {
            guard !failedRecordingIDs.contains(recordingID),
                  visibleRecordingIDs.contains(recordingID),
                  jobs.count == 1,
                  jobs.first?.isFailedRecordingPlaceholder == true else { continue }
            transcriptionJobsByRecordingID.removeValue(forKey: recordingID)
        }
    }

    func refreshTranscriptAfterJobSucceeded(recording: CloudRecording, job: TranscriptionJob) async throws {
        locallyManagedRecordingUpdatedAt[recording.id] = Date()
        hasNewerVersionForSelection = selectedRecordingID == recording.id ? false : hasNewerVersionForSelection
        recordingIDsWithNewerVersions.remove(recording.id)

        let transcript = try await loadCompletedTranscript(recordingID: recording.id, jobID: job.id)
        transcriptCache[recording.id] = transcript
        applySummaryTitleFromTranscript(transcript, to: recording.id)
        try syncTranscriptToLocalSessionIfLinked(recording: recording, transcript: transcript, job: job)
        await refreshRecordingDetailAfterLocalProcessing(recordingID: recording.id)
        clearNewerVersionFlagIfCurrent(recordingID: recording.id, transcript: transcript)
        await persistCacheSnapshot()
    }

    func loadTranscriptVersion(recordingID: String, jobID: String) async throws -> TranscriptResponse {
        try await runAuthorized { client in
            try await client.getRecordingTranscript(id: recordingID, jobId: jobID)
        }
    }

    private func loadCompletedTranscript(recordingID: String, jobID: String) async throws -> TranscriptResponse {
        var transcript = try await runAuthorized { client in
            try await client.getRecordingTranscript(id: recordingID, jobId: jobID)
        }

        // The transcription job can reach `succeeded` before the summary JSON
        // has been amended onto the same transcript row. Keep the current
        // detail page moving forward in-place instead of waiting for the user
        // to switch away and back, which would incidentally refetch detail.
        for _ in 0..<12 where !Self.hasSummaryContent(transcript) {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            transcript = try await runAuthorized { client in
                try await client.getRecordingTranscript(id: recordingID, jobId: jobID)
            }
            if transcript.summaryStatus == .failed || transcript.summaryStatus == .skipped {
                break
            }
        }

        return transcript
    }

    private func refreshRecordingDetailAfterLocalProcessing(recordingID: String) async {
        do {
            let detail = try await runAuthorized { client in
                try await client.getRecording(id: recordingID)
            }
            replaceRecording(detail)
            transcriptCacheRecordingUpdatedAt[recordingID] = detail.updatedAt ?? Date()
            if selectedRecordingID == recordingID {
                hasNewerVersionForSelection = false
            }
            recordingIDsWithNewerVersions.remove(recordingID)
        } catch {
            // The transcript is already refreshed; a detail refresh failure
            // should not resurrect the newer-version banner. Surface it as
            // cache-warning noise instead of blocking the current content.
            cacheWarningMessage = "Showing refreshed transcript · Detail metadata refresh failed"
            isShowingCachedData = true
        }
    }

    private func clearNewerVersionFlagIfCurrent(recordingID: String, transcript: TranscriptResponse) {
        guard selectedRecordingID == recordingID,
              Self.shouldClearNewerVersionFlag(
                  activeTranscriptId: recordings.first(where: { $0.id == recordingID })?.activeTranscriptId,
                  loadedTranscriptId: transcript.id
              ) else {
            return
        }
        hasNewerVersionForSelection = false
        recordingIDsWithNewerVersions.remove(recordingID)
    }

    nonisolated static func shouldClearNewerVersionFlag(
        activeTranscriptId: String?,
        loadedTranscriptId: String
    ) -> Bool {
        guard let activeTranscriptId, !activeTranscriptId.isEmpty else {
            return true
        }
        return activeTranscriptId == loadedTranscriptId
    }

    nonisolated static func hasSummaryContent(_ transcript: TranscriptResponse) -> Bool {
        if transcript.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        return transcript.summaryInsights?.isEmpty == false
    }


}
