import AppKit
import Foundation

@MainActor
extension CloudLibraryStore {
    var hasVisibleLibraryData: Bool {
        !recordings.isEmpty || state == .empty || state == .loaded
    }

    func handleRefreshFailure(_ error: Error, preserveVisibleData: Bool) {
        guard preserveVisibleData, hasVisibleLibraryData else {
            apply(error: error)
            return
        }
        let wasShowingCachedData = isShowingCachedData
        cacheWarningMessage = refreshFailureMessage(for: error, wasShowingCachedData: wasShowingCachedData)
        isShowingCachedData = wasShowingCachedData
        if recordings.isEmpty {
            state = .empty
        } else {
            state = .loaded
        }
    }

    func refreshFailureMessage(for error: Error, wasShowingCachedData: Bool) -> String {
        let prefix = wasShowingCachedData ? "Showing cached data" : "Refresh failed"
        if let apiError = error as? RecappiAPIError, apiError == .unauthorized {
            return "\(prefix) · Sign in again to refresh"
        }
        if error is RecappiSessionError {
            return "\(prefix) · Sign in again to refresh"
        }
        return wasShowingCachedData ? "Showing cached data · Refresh failed" : "Refresh failed · Current data kept"
    }

    func restoreCacheIfAvailable() async -> Bool {
        guard let context = cacheContext() else { return false }
        guard let snapshot = await cache.loadSnapshot(
            userId: context.userId,
            backendOrigin: context.backendOrigin
        ) else {
            return false
        }

        recordings = snapshot.decodedRecordings
        nextCursor = snapshot.nextCursor
        totalRecordingCount = nil
        billingStatus = snapshot.decodedBillingStatus
        transcriptCache = snapshot.decodedTranscripts
        transcriptionJobsByRecordingID = snapshot.decodedTranscriptionJobsByRecordingID
        // Older snapshot versions did not persist this map. The decoded
        // dictionary will be empty for those caches; the shape-based
        // fallback in `loadTranscriptForSelection` is intentionally the
        // safety net so users on legacy caches still get summary recovery
        // on the next selection.
        transcriptCacheRecordingUpdatedAt = snapshot.decodedTranscriptCacheRecordingUpdatedAt
        lastSuccessfulRefreshAt = snapshot.savedAt
        isShowingCachedData = true
        cacheWarningMessage = nil

        if let selectedID = snapshot.selectedRecordingID,
           recordings.contains(where: { $0.id == selectedID }) {
            selectedRecordingID = selectedID
        } else {
            selectedRecordingID = recordings.first?.id
        }

        await refreshLocalSessionLinks()
        state = recordings.isEmpty ? .empty : .loaded
        return true
    }

    func persistCacheSnapshot() async {
        guard let context = cacheContext() else { return }
        let snapshot = CloudLibrarySnapshot(
            userId: context.userId,
            backendOrigin: context.backendOrigin,
            savedAt: lastSuccessfulRefreshAt ?? Date(),
            recordings: recordings,
            nextCursor: nextCursor,
            selectedRecordingID: selectedRecordingID,
            billingStatus: billingStatus,
            transcriptCache: transcriptCache,
            transcriptionJobsByRecordingID: transcriptionJobsByRecordingID,
            transcriptCacheRecordingUpdatedAt: transcriptCacheRecordingUpdatedAt
        )
        await cache.saveSnapshot(snapshot)
    }

    func cacheContext() -> (userId: String, backendOrigin: String)? {
        guard let session = sessionStore.currentSession else { return nil }
        return (
            userId: session.userId,
            backendOrigin: AuthSessionStore.normalizeOrigin(config.effectiveBackendBaseURL)
        )
    }

    func transcriptMessage(for error: Error) -> String {
        if let cloudError = error as? CloudLibraryError {
            return cloudError.localizedDescription
        }
        if let apiError = error as? RecappiAPIError {
            switch apiError {
            case .http(let statusCode, _) where statusCode == 404:
                return "Transcript is not available for this recording yet."
            default:
                return apiError.localizedDescription
            }
        }
        return error.localizedDescription
    }


}
