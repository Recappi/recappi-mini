import AppKit
import Foundation

@MainActor
extension CloudLibraryStore {
    private nonisolated static let localPipelineNewerVersionSuppressionInterval: TimeInterval = 30 * 60

    func select(_ recording: CloudRecording) {
        PerfLog.event("select", extra: "id=\(recording.id.prefix(8))")
        PerfLog.start("select.until.firstRender")
        selectedRecordingID = recording.id
        transcriptErrorMessage = nil
        hasNewerVersionForSelection = false
        // Pre-mark the recording as loading if its transcript content has
        // not been cached yet. The detail view will trigger
        // `loadTranscriptForSelection` shortly via `.task(id:)`, but
        // `refreshSelectedDetailIfNeeded` may race ahead of it and read
        // `transcriptLoadingRecordingIDs` before it gets populated. Setting
        // the flag here closes that window so the banner does not flash.
        if transcriptCache[recording.id] == nil {
            setTranscriptLoading(true, for: recording.id)
        }
        scheduleCachePersist()
        scheduleSelectedDetailRefresh()
    }

    func upsertLocalProcessingRecording(_ recording: CloudRecording, latestJob: TranscriptionJob? = nil) {
        locallyManagedRecordingUpdatedAt[recording.id] = Date()
        replaceRecording(recording)
        recordings.sort { lhs, rhs in
            (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
        }
        if let latestJob {
            upsertJob(latestJob, for: recording.id)
        }
        if selectedRecordingID == nil {
            selectedRecordingID = recording.id
        }
        state = recordings.isEmpty ? .empty : .loaded
        lastSuccessfulRefreshAt = lastSuccessfulRefreshAt ?? Date()
        cacheWarningMessage = nil
        Task { await refreshLocalSessionLinks() }
        scheduleCachePersist()
    }

    func removeLocalProcessingRecording(id recordingID: String) {
        recordings.removeAll { $0.id == recordingID }
        transcriptCache.removeValue(forKey: recordingID)
        transcriptCacheRecordingUpdatedAt.removeValue(forKey: recordingID)
        transcriptionJobsByRecordingID.removeValue(forKey: recordingID)
        locallyManagedRecordingUpdatedAt.removeValue(forKey: recordingID)
        playbackAudioURLsByRecordingID.removeValue(forKey: recordingID)
        localSessionURLsByRecordingID.removeValue(forKey: recordingID)
        summaryRefreshAttemptedRecordingIDs.remove(recordingID)
        if selectedRecordingID == recordingID {
            selectedRecordingID = recordings.first?.id
        }
        state = recordings.isEmpty ? .empty : .loaded
        scheduleCachePersist()
    }

    func scheduleSelectedDetailRefresh() {
        selectionDetailRefreshTask?.cancel()
        selectionDetailRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshSelectedDetailIfNeeded()
        }
    }

    func scheduleCachePersist() {
        cachePersistTask?.cancel()
        cachePersistTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.persistCacheSnapshot()
        }
    }

    func refreshSelectedDetailIfNeeded() async {
        guard let recordingID = selectedRecordingID else { return }
        // Snapshot the comparison basis *before* the await so we can detect
        // whether the cloud-side `activeTranscriptId` advanced past whatever we
        // are currently rendering. Reading these after `replaceRecording` would
        // see the freshly fetched values and never produce a diff.
        let cachedRecording = recordings.first(where: { $0.id == recordingID })
        let cachedActiveTranscriptId = cachedRecording?.activeTranscriptId
        // Use the transcript-cache-time snapshot of `recording.updatedAt`
        // rather than the live `recordings[id].updatedAt`. The live value is
        // refreshed independently by `listRecordings()` and would already
        // reflect any post-summarize advance, masking the staleness of the
        // transcript itself. The snapshot is set in
        // `loadTranscriptForSelection` at the moment a transcript is
        // written to `transcriptCache`. If we do not have a snapshot for
        // this recording (e.g. cache loaded from an older
        // `CloudLibrarySnapshot` version that did not persist the map),
        // we fall back to the live recording timestamp as a degraded
        // approximation; the shape-based fallback in
        // `loadTranscriptForSelection` is the safety net for that case.
        let cachedUpdatedAt = transcriptCacheRecordingUpdatedAt[recordingID]
            ?? cachedRecording?.updatedAt
        let cachedTranscriptResponseId = transcriptCache[recordingID]?.id
        do {
            let detail = try await runAuthorized { client in
                try await client.getRecording(id: recordingID)
            }
            guard !Task.isCancelled else { return }
            // Selection race guard: user may have selected another recording
            // while we awaited. Don't leak this banner state onto a different
            // recording.
            guard selectedRecordingID == recordingID else { return }
            let isLoading = transcriptLoadingRecordingIDs.contains(recordingID)
            let metadataStale = Self.shouldFlagNewerVersion(
                cachedActiveTranscriptId: cachedActiveTranscriptId,
                freshActiveTranscriptId: detail.activeTranscriptId,
                cachedTranscriptResponseId: cachedTranscriptResponseId,
                isTranscriptLoading: isLoading
            )
            // Same-id-different-content case: backend may amend the existing
            // transcript object with a summary later (transcribe is sync,
            // summarize is async). `activeTranscriptId` stays the same but
            // the recording's `updatedAt` advances. The previous detection
            // missed this and left the user with a stale-content cache that
            // never refreshed (no banner, no summary). Catch it via
            // updatedAt diff.
            let contentUpdatedSinceCache = !isLoading
                && Self.shouldFlagOnUpdatedAtAdvance(
                    cachedUpdatedAt: cachedUpdatedAt,
                    freshUpdatedAt: detail.updatedAt
                )
            let suppressLocalPipelineBanner = Self.shouldSuppressNewerVersionBannerForLocalPipeline(
                lastLocalUpdateAt: locallyManagedRecordingUpdatedAt[recordingID],
                now: Date()
            )
            if metadataStale || (contentUpdatedSinceCache && !suppressLocalPipelineBanner) {
                hasNewerVersionForSelection = true
            }
            // When the staleness is specifically the "content updated for the
            // same activeTranscriptId" case, the local transcript cache holds
            // the pre-update body. Drop it and explicitly reload — we cannot
            // rely on the detail view's `.task(id: recording.id)` to refire
            // because the recording id has not changed; SwiftUI only restarts
            // a `.task(id:)` when the bound id actually flips.
            //
            // Treating this as a "cloud detail freshness heuristic" rather
            // than a precise transcript diff: `updatedAt` may advance for
            // non-transcript reasons (billing/source metadata changes), in
            // which case the worst we do is refetch a transcript that
            // matches the local copy — idempotent and cheap.
            if contentUpdatedSinceCache {
                transcriptCache.removeValue(forKey: recordingID)
                transcriptCacheRecordingUpdatedAt.removeValue(forKey: recordingID)
                transcriptionJobsByRecordingID.removeValue(forKey: recordingID)
                // A fresh fetch should be allowed again — clear the
                // shape-based fallback's once-per-session guard so this
                // recording can re-attempt if a future cache lands without
                // summary content.
                summaryRefreshAttemptedRecordingIDs.remove(recordingID)
            }
            if contentUpdatedSinceCache && suppressLocalPipelineBanner {
                DiagnosticsLog.event(
                    "cloud",
                    "newer_version.suppressed_local_pipeline recording=\(recordingID.prefix(8))"
                )
                hasNewerVersionForSelection = false
            }
            // Test-only escape hatch: lets reviewers see the
            // `newerVersionStrip` banner without orchestrating a real
            // concurrent retranscribe. Requires the explicit
            // `RECAPPI_TEST_FORCE_NEWER_VERSION_BANNER=1` env var, so it
            // cannot fire in normal operation.
            if UITestModeConfiguration.shared.forceNewerVersionBannerForTesting {
                hasNewerVersionForSelection = true
            }
            replaceRecording(detail)
            cacheWarningMessage = nil
            await persistCacheSnapshot()
            // After dropping the stale transcript cache above we must drive
            // the reload ourselves — `.task(id: recording.id)` in the detail
            // view will not refire while the recording id is unchanged.
            if contentUpdatedSinceCache {
                await loadTranscriptForSelection()
                await loadJobHistoryForSelection()
            }
        } catch {
            if let apiError = error as? RecappiAPIError, apiError == .unauthorized {
                handleRefreshFailure(error, preserveVisibleData: hasVisibleLibraryData)
            } else {
                cacheWarningMessage = "Showing cached data · Detail refresh failed"
                isShowingCachedData = true
            }
        }
    }

    /// Pure decision for "did the recording's content advance even though
    /// `activeTranscriptId` stayed the same?".
    ///
    /// Backend produces transcripts in two passes — `transcribe` is sync and
    /// fixes the `activeTranscriptId`; `summarize` runs later and amends the
    /// same transcript row with `summary` / `summaryInsights`. The local
    /// `transcriptCache` is keyed by recording id and only refreshed when
    /// `loadTranscriptForSelection` finds an empty slot, so a transcript
    /// cached *before* the summary landed will sit forever showing only the
    /// raw text. This helper detects that scenario by comparing
    /// `recording.updatedAt` rather than `activeTranscriptId`.
    nonisolated static func shouldFlagOnUpdatedAtAdvance(
        cachedUpdatedAt: Date?,
        freshUpdatedAt: Date?
    ) -> Bool {
        guard let fresh = freshUpdatedAt else { return false }
        guard let cached = cachedUpdatedAt else { return false }
        return fresh > cached
    }

    /// Suppress the "newer cloud version" strip only for the short window
    /// immediately after this app's own upload/transcription pipeline touched
    /// the recording. The normal path now refreshes server detail as soon as
    /// processing completes; this guard only catches late async summarization
    /// updates from the same pipeline, and expires so real remote edits are
    /// not hidden later in the session.
    nonisolated static func shouldSuppressNewerVersionBannerForLocalPipeline(
        lastLocalUpdateAt: Date?,
        now: Date,
        interval: TimeInterval = localPipelineNewerVersionSuppressionInterval
    ) -> Bool {
        guard let lastLocalUpdateAt else { return false }
        return now.timeIntervalSince(lastLocalUpdateAt) <= interval
    }

    /// Pure decision for "should the newer-version banner show?".
    ///
    /// Two staleness shapes both produce `true`:
    /// 1. **Metadata advanced**: cached recording's `activeTranscriptId`
    ///    differs from the cloud's fresh value (a re-transcribe happened
    ///    elsewhere). This is the obvious case.
    /// 2. **Local content missing the active transcript**: even when the
    ///    cached recording metadata already shows the latest
    ///    `activeTranscriptId`, the local `transcriptCache` may hold the
    ///    *previous* transcript (or nothing at all). v1.0.36 missed this
    ///    case because the metadata diff was zero but the user still saw
    ///    stale / empty Summary content.
    ///
    /// `isTranscriptLoading` lets the caller suppress the banner while the
    /// transcript is actively being fetched, so users don't see it flash
    /// during the normal "open recording → load transcript" sequence.
    nonisolated static func shouldFlagNewerVersion(
        cachedActiveTranscriptId: String?,
        freshActiveTranscriptId: String?,
        cachedTranscriptResponseId: String?,
        isTranscriptLoading: Bool = false
    ) -> Bool {
        guard let fresh = freshActiveTranscriptId else {
            // No active transcript on the cloud side (e.g., a Failed
            // recording that never produced one). Nothing to surface.
            return false
        }
        if isTranscriptLoading {
            // Wait for the in-flight load to settle before deciding.
            // Otherwise the banner would flash on every open.
            return false
        }
        // Local already has the fresh transcript content cached: never flag,
        // regardless of recording metadata's `activeTranscriptId` lag.
        if let cachedTranscriptResponseId, cachedTranscriptResponseId == fresh {
            return false
        }
        // Case 1: recording metadata's activeTranscriptId advanced away from
        // what we previously cached.
        if let cached = cachedActiveTranscriptId, cached != fresh {
            return true
        }
        // Case 2: metadata is consistent (or first load), but local
        // transcript content does not match the active transcript. Only
        // flag when we have already touched this recording (cached
        // recording metadata exists). For a first-time open we have no
        // basis to claim staleness.
        if cachedActiveTranscriptId != nil,
           cachedTranscriptResponseId != nil,
           cachedTranscriptResponseId != fresh {
            return true
        }
        return false
    }

    func acknowledgeNewerVersion() async {
        guard let recordingID = selectedRecordingID else { return }
        // Drop caches first so the next loaders fetch fresh content.
        transcriptCache.removeValue(forKey: recordingID)
        transcriptCacheRecordingUpdatedAt.removeValue(forKey: recordingID)
        transcriptionJobsByRecordingID.removeValue(forKey: recordingID)
        // The user explicitly asked for a refresh; let the shape-based
        // fallback retry once more if necessary.
        summaryRefreshAttemptedRecordingIDs.remove(recordingID)
        await loadTranscriptForSelection()
        await loadJobHistoryForSelection()
        // Only clear the banner once we actually have *the active* transcript
        // for the current selection. Loading some other transcript (e.g. an
        // older job that the API returned) would leave the user staring at
        // stale content with the banner gone. Stay strict: id must match the
        // recording's `activeTranscriptId`.
        if selectedRecordingID == recordingID,
           let recording = recordings.first(where: { $0.id == recordingID }),
           let active = recording.activeTranscriptId,
           transcriptCache[recordingID]?.id == active {
            hasNewerVersionForSelection = false
        } else if selectedRecordingID == recordingID,
                  recordings.first(where: { $0.id == recordingID })?.activeTranscriptId == nil,
                  transcriptCache[recordingID] != nil {
            // Recording has no active transcript (rare: a Failed recording
            // that we somehow reached the banner state on). If we got *any*
            // transcript content back, treat it as resolved. This branch is
            // a safety valve, not the common path.
            hasNewerVersionForSelection = false
        }
        await persistCacheSnapshot()
    }


}
