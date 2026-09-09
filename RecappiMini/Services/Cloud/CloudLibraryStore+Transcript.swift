import AppKit
import Foundation

@MainActor
extension CloudLibraryStore {
    /// Load the selected recording's job history, at most one request per
    /// recording in flight at a time.
    ///
    /// - Parameter requiresFreshFetch: pass `true` only from callers that
    ///   invalidated state before calling — dropped the cached job rows, or
    ///   created a job row the server has yet to report. Those callers are
    ///   guaranteed a request issued *after* their own mutation even when the
    ///   in-flight guard below drops them. Plain UI triggers leave it `false`:
    ///   they mutate nothing, so the response the in-flight owner is already
    ///   about to apply is correct for them too, and three simultaneous
    ///   triggers coalesce into one request instead of two.
    func loadJobHistoryForSelection(requiresFreshFetch: Bool = false) async {
        guard let recording = selectedRecording else { return }
        guard !recording.isLocalOnlyRecording else {
            transcriptionJobsByRecordingID[recording.id] = transcriptionJobsByRecordingID[recording.id] ?? []
            return
        }
        // Leading edge: at most one GET /api/recordings/:id/jobs in flight per
        // recording. `jobHistoryLoadingRecordingIDs` is written *only* here
        // (insert below, remove at the end of this function) and both writes
        // are synchronous, so there is no `await` between this check and the
        // claim — the main actor cannot interleave a second caller in.
        guard !jobHistoryLoadingRecordingIDs.contains(recording.id) else {
            if requiresFreshFetch {
                jobHistoryReloadRequestedRecordingIDs.insert(recording.id)
            }
            return
        }
        // The request below is issued *now*, so it already satisfies any
        // reload queued before this point — including one a cancelled or
        // deselected owner had to leave behind. Draining it here keeps a
        // stale flag from buying a spurious extra fetch later.
        jobHistoryReloadRequestedRecordingIDs.remove(recording.id)
        setJobHistoryLoading(true, for: recording.id)

        // The request is *shared*: every caller the guard above dropped is
        // relying on the rows this one applies. Issue it from an unstructured
        // task so it is not a child of whichever view Task happened to win the
        // claim. Unstructured tasks do not inherit cancellation, so tearing
        // down the detail view — or `scheduleSelectedDetailRefresh` cancelling
        // and replacing `selectionDetailRefreshTask` — no longer aborts a
        // request that other callers were coalesced onto and are left with no
        // way to re-issue.
        //
        // `self` is captured strongly, but the task is awaited immediately and
        // never stored, so it cannot outlive this call or form a cycle.
        // Awaiting a `Task<Void, Never>` cannot throw and is not interrupted by
        // *our* cancellation, so the claim release below still runs exactly
        // once on every path, including when the request throws.
        await Task { @MainActor [self] in
            #if DEBUG
            await beforeJobHistoryRequestForTesting?()
            #endif
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
                DiagnosticsLog.error(
                    "cloud",
                    "job_history.load.failed recordingID=\(recording.id) \(DiagnosticsLog.errorSummary(error))"
                )
                if selectedRecordingID == recording.id {
                    cacheWarningMessage = "Showing cached data · Job status refresh failed"
                    isShowingCachedData = true
                }
            }
        }.value

        setJobHistoryLoading(false, for: recording.id)

        // Trailing edge: a caller that had invalidated state was dropped while
        // we were in flight. Its need post-dates the response we just applied
        // (dropped caches in `acknowledgeNewerVersion` /
        // `refreshSelectedDetailIfNeeded`, or a job row the local pipeline
        // created), so issue exactly one more fetch.
        //
        // Deliberately *not* gated on `Task.isCancelled`. Because the request
        // above is unstructured, a cancelled owner still received its response
        // and can still service the queued reload; bailing here would strand
        // the caller it dropped, and nothing else is guaranteed to run —
        // `.task(id:)` will not refire while the recording id is unchanged and
        // every other caller needs a fresh user action.
        //
        // `Set.remove` mutates and `if` conditions short-circuit left to
        // right, so the flag is consumed *last* — checking it first would let
        // an owner whose selection moved on swallow the queued reload without
        // issuing anything. Bailing here leaves the flag set; the leading edge
        // above drains it on the next fetch for this recording.
        guard selectedRecordingID == recording.id else { return }
        if jobHistoryReloadRequestedRecordingIDs.remove(recording.id) != nil {
            // Carry the guarantee forward: if this re-fetch is itself dropped
            // by a newer owner it must queue again rather than coalesce away.
            // Bounded: the id is removed before re-entry and only a *new*
            // invalidating caller can put it back.
            await loadJobHistoryForSelection(requiresFreshFetch: true)
        }
    }

    /// Retry the failed parts of a smart-chunk job. On success, merges the
    /// fresh status + progress into the job row — flipping it back to an active
    /// status, which changes `selectedActiveJobPollingKey` and so restarts the
    /// active-job polling automatically. Re-throws so the detail panel can show
    /// a soft "already retrying" hint on a 409 or an error otherwise.
    func retryFailedChunks(recordingID: String, jobID: String) async throws {
        let result = try await runAuthorized { client in
            try await client.retryFailedChunks(jobId: jobID)
        }
        var jobs = transcriptionJobsByRecordingID[recordingID] ?? []
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let job = jobs[index]
        jobs[index] = TranscriptionJob(
            id: job.id,
            status: result.status,
            transcriptId: job.transcriptId,
            provider: job.provider,
            model: job.model,
            language: job.language,
            prompt: job.prompt,
            error: nil,
            attempts: job.attempts,
            enqueuedAt: job.enqueuedAt,
            startedAt: job.startedAt,
            finishedAt: job.finishedAt,
            chunkProgress: result.chunkProgress
        )
        transcriptionJobsByRecordingID[recordingID] = jobs
        await persistCacheSnapshot()
    }

    /// Lightweight job-list reload for the discovery poll: no loading spinner,
    /// and only mutates `@Published` state when the job list actually changed,
    /// so an idle poll never churns the UI. Uses the list endpoint (which
    /// carries `chunkProgress`), so it can surface a transcription started
    /// elsewhere (other device / backend) that the per-job poll can't see —
    /// the per-job poll only refreshes jobs the app already knows about.
    func refreshSelectedRecordingJobsQuietly() async {
        guard let recording = selectedRecording, !recording.isLocalOnlyRecording else { return }
        do {
            let page = try await runAuthorized { client in
                try await client.listRecordingJobs(recordingId: recording.id, limit: 50)
            }
            guard selectedRecordingID == recording.id else { return }
            if transcriptionJobsByRecordingID[recording.id] != page.items {
                transcriptionJobsByRecordingID[recording.id] = page.items
                await persistCacheSnapshot()
            }
        } catch {
            // Best-effort background discovery — never surface an error or
            // flip the cache-warning banner for a silent poll.
        }
    }

    /// Periodically reload the selected recording's job list so a transcription
    /// started elsewhere is discovered and its progress panel appears without a
    /// manual refresh. Once a discovered job is active, the polling key changes
    /// and `pollSelectedActiveJobsUntilTerminal` takes over the 2s progress
    /// updates; this loop just keeps watching for new jobs. Runs while the
    /// recording stays selected (cancelled by the view's `.task(id:)`).
    func pollSelectedRecordingJobDiscovery() async {
        guard let recordingID = selectedRecordingID else { return }
        while !Task.isCancelled {
            await refreshSelectedRecordingJobsQuietly()
            guard selectedRecordingID == recordingID else { return }
            let hasActiveJob = (transcriptionJobsByRecordingID[recordingID] ?? [])
                .contains { $0.status.isActive }
            // Slow cadence while the per-job poll is already covering an active
            // job; a touch quicker while idle so an externally-started job is
            // picked up promptly. Single small request, scoped to one recording.
            try? await Task.sleep(for: .seconds(hasActiveJob ? 10 : 5))
        }
    }

    func pollSelectedActiveJobsUntilTerminal() async {
        guard let recording = selectedRecording else { return }
        let activeJobs = (transcriptionJobsByRecordingID[recording.id] ?? [])
            .filter { $0.status.isActive }
        let shouldPollSummary = transcriptCache[recording.id].map {
            Self.shouldPollSummary(
                cachedTranscript: $0,
                recordingStatus: recording.status
            )
        } ?? false
        guard !activeJobs.isEmpty || shouldPollSummary else { return }

        await pollActiveJobsUntilTerminal(
            recordingID: recording.id,
            jobIDs: activeJobs.map(\.id),
            pollSummary: shouldPollSummary
        )
    }

    func pollActiveJobsUntilTerminal(
        recordingID: String,
        jobIDs: [String],
        pollSummary: Bool = false,
        onJobUpdate: (@MainActor @Sendable (TranscriptionJob) -> Void)? = nil
    ) async {
        var idsToRefresh = jobIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var shouldPollSummary = pollSummary
        guard !idsToRefresh.isEmpty || shouldPollSummary else { return }

        while !Task.isCancelled {
            if !idsToRefresh.isEmpty {
                await refreshJobs(
                    recordingID: recordingID,
                    jobIDs: idsToRefresh,
                    onJobUpdate: onJobUpdate
                )
            }
            if shouldPollSummary {
                await refreshActiveSummaryForRecordingIfNeeded(recordingID: recordingID)
            }
            idsToRefresh = (transcriptionJobsByRecordingID[recordingID] ?? [])
                .filter { $0.status.isActive }
                .map(\.id)
            if let recording = recordings.first(where: { $0.id == recordingID }),
               let transcript = transcriptCache[recordingID] {
                shouldPollSummary = Self.shouldPollSummary(
                    cachedTranscript: transcript,
                    recordingStatus: recording.status
                )
            } else {
                shouldPollSummary = false
            }
            guard !idsToRefresh.isEmpty || shouldPollSummary else { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func loadTranscriptForSelection() async {
        guard let recording = selectedRecording else { return }
        guard !recording.isLocalOnlyRecording else {
            setTranscriptLoading(false, for: recording.id)
            return
        }
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
            DiagnosticsLog.error(
                "cloud",
                "transcript.load.failed recordingID=\(loadingRecordingID) \(DiagnosticsLog.errorSummary(error))"
            )
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
        return !hasSummaryContent(cachedTranscript)
    }

    nonisolated static func shouldPollSummary(
        cachedTranscript: TranscriptResponse,
        recordingStatus: CloudRecordingStatus
    ) -> Bool {
        guard recordingStatus == .ready else { return false }
        return cachedTranscript.summaryStatus?.isActive == true
    }


    func refreshJobs(
        recordingID: String,
        jobIDs: [String],
        onJobUpdate: (@MainActor @Sendable (TranscriptionJob) -> Void)? = nil
    ) async {
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
                onJobUpdate?(job)
                didUpdateJobs = true
                if previousStatus != .succeeded, job.status == .succeeded,
                   let recording = recordings.first(where: { $0.id == recordingID }) {
                    try await refreshTranscriptAfterJobSucceeded(recording: recording, job: job)
                }
            } catch let error as RecappiAPIError where error == .unauthorized {
                apply(error: error)
                return
            } catch {
                DiagnosticsLog.error(
                    "cloud",
                    "job.refresh.failed recordingID=\(recordingID) jobID=\(jobID) \(DiagnosticsLog.errorSummary(error))"
                )
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

    private func refreshActiveSummaryForRecordingIfNeeded(recordingID: String) async {
        guard let recording = recordings.first(where: { $0.id == recordingID }),
              let cachedTranscript = transcriptCache[recordingID],
              Self.shouldPollSummary(
                  cachedTranscript: cachedTranscript,
                  recordingStatus: recording.status
              ) else {
            return
        }

        do {
            let transcript = try await runAuthorized { client in
                try await client.getRecordingTranscript(id: recordingID)
            }
            try Task.checkCancellation()
            let currentTranscript = transcriptCache[recordingID] ?? cachedTranscript
            guard Self.shouldPollSummary(
                cachedTranscript: currentTranscript,
                recordingStatus: recording.status
            ) else {
                return
            }

            let didChange = transcriptCache[recordingID] != transcript
            transcriptCache[recordingID] = transcript
            applySummaryTitleFromTranscript(transcript, to: recordingID)
            try syncTranscriptToLocalSessionIfLinked(recording: recording, transcript: transcript)
            clearNewerVersionFlagIfCurrent(recordingID: recordingID, transcript: transcript)
            if let updatedAt = recording.updatedAt {
                transcriptCacheRecordingUpdatedAt[recordingID] = updatedAt
            }
            if !Self.shouldPollSummary(cachedTranscript: transcript, recordingStatus: recording.status) {
                summaryRefreshAttemptedRecordingIDs.remove(recordingID)
            }
            if didChange {
                await persistCacheSnapshot()
            }
        } catch is CancellationError {
            return
        } catch let error as RecappiAPIError where error == .unauthorized {
            apply(error: error)
        } catch {
            DiagnosticsLog.warning(
                "cloud",
                "summary.refresh.failed recordingID=\(recordingID) \(DiagnosticsLog.errorSummary(error))"
            )
        }
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
            DiagnosticsLog.warning(
                "cloud",
                "recording.detail.refresh_after_transcript.failed recordingID=\(recordingID) \(DiagnosticsLog.errorSummary(error))"
            )
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
