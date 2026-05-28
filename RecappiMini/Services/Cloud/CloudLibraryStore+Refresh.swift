import AppKit
import Foundation

@MainActor
extension CloudLibraryStore {
    func loadInitialIfNeeded() async {
        guard !isRemoteRefreshInFlight else { return }
        let restoredCache = recordings.isEmpty ? await restoreCacheIfAvailable() : false
        await refreshFromRemote(preserveVisibleDataOnFailure: restoredCache || hasVisibleLibraryData)
    }

    func refresh() async {
        let restoredCache = recordings.isEmpty ? await restoreCacheIfAvailable() : false
        await refreshFromRemote(preserveVisibleDataOnFailure: restoredCache || hasVisibleLibraryData)
    }

    func refreshFromRemote(preserveVisibleDataOnFailure: Bool) async {
        guard !isRemoteRefreshInFlight else { return }
        isRemoteRefreshInFlight = true
        defer {
            isRemoteRefreshInFlight = false
            isRefreshing = false
        }

        let hasLocalOnlyRecordings = await mergeLocalOnlyRecordingsFromDisk()
        guard await prepareForAuthenticatedRequest() else {
            if hasLocalOnlyRecordings || !recordings.isEmpty {
                state = .loaded
                cacheWarningMessage = "Showing local recordings · Sign in to upload"
            }
            return
        }
        isRefreshing = hasVisibleLibraryData
        if recordings.isEmpty {
            state = .loading
        } else if state != .empty {
            state = .loaded
        }

        await refreshBillingStatus(allowStaleOnFailure: preserveVisibleDataOnFailure || hasVisibleLibraryData)

        do {
            let page = try await runAuthorized { client in
                try await client.listRecordings(limit: pageLimit)
            }
            let previousSelection = selectedRecordingID
            let remoteRecordings = mergeWithCachedRecordingDetails(page.items)
            let localOnlyRecordings = await loadLocalOnlyRecordings()
            recordings = mergeWithLocalOnlyRecordings(
                remoteRecordings,
                localOnlyRecordings: localOnlyRecordings
            )
            nextCursor = page.nextCursor
            totalRecordingCount = await resolvedTotalRecordingCount(from: page)
            if let previousSelection, recordings.contains(where: { $0.id == previousSelection }) {
                selectedRecordingID = previousSelection
            } else {
                selectedRecordingID = recordings.first?.id
            }
            selectDefaultRecordingIfNeeded()
            await refreshLocalSessionLinks()
            lastSuccessfulRefreshAt = Date()
            isShowingCachedData = false
            cacheWarningMessage = nil
            state = recordings.isEmpty ? .empty : .loaded
            seedFailedRecordingJobPlaceholdersIfNeeded()
            await persistCacheSnapshot()
        } catch {
            handleRefreshFailure(error, preserveVisibleData: preserveVisibleDataOnFailure || hasVisibleLibraryData)
        }
    }

    func refreshBillingStatus() async {
        await refreshBillingStatus(allowStaleOnFailure: false)
    }

    func refreshBillingStatus(allowStaleOnFailure: Bool) async {
        guard await prepareForAuthenticatedRequest() else { return }
        isLoadingBilling = true
        billingErrorMessage = nil

        do {
            billingStatus = try await runAuthorized { client in
                try await client.getBillingStatus()
            }
            if lastSuccessfulRefreshAt == nil {
                lastSuccessfulRefreshAt = Date()
            }
        } catch let error as RecappiAPIError where error == .unauthorized {
            if allowStaleOnFailure, hasVisibleLibraryData {
                billingErrorMessage = NetworkErrorPresenter.userFacingMessage(for: error)
                cacheWarningMessage = refreshFailureMessage(for: error, wasShowingCachedData: isShowingCachedData)
            } else {
                apply(error: error)
            }
        } catch {
            billingErrorMessage = NetworkErrorPresenter.userFacingMessage(for: error)
        }

        isLoadingBilling = false
    }

    func resolvedTotalRecordingCount(from firstPage: CloudRecordingsPage) async -> Int? {
        if let totalCount = firstPage.totalCount {
            return totalCount
        }

        var count = firstPage.items.count
        var cursor = firstPage.nextCursor
        while let currentCursor = cursor, !currentCursor.isEmpty {
            do {
                let page = try await runAuthorized { client in
                    try await client.listRecordings(limit: 100, cursor: currentCursor)
                }
                if let totalCount = page.totalCount {
                    return totalCount
                }
                count += page.items.count
                cursor = page.nextCursor
            } catch {
                DiagnosticsLog.warning(
                    "cloud",
                    "total_count.page.failed cursorHash=\(currentCursor.hashValue) \(DiagnosticsLog.errorSummary(error))"
                )
                return nil
            }
        }
        return count
    }

    func loadMore() async {
        guard !isLoadingMore else { return }
        guard let cursor = nextCursor, !cursor.isEmpty else { return }
        guard await prepareForAuthenticatedRequest() else { return }
        isLoadingMore = true

        do {
            let page = try await runAuthorized { client in
                try await client.listRecordings(limit: pageLimit, cursor: cursor)
            }
            var existingIDs = Set(recordings.map(\.id))
            for recording in mergeWithCachedRecordingDetails(page.items) where existingIDs.insert(recording.id).inserted {
                recordings.append(recording)
            }
            recordings = Self.deduplicatedRecordings(recordings)
            nextCursor = page.nextCursor
            totalRecordingCount = page.totalCount ?? totalRecordingCount ?? (nextCursor == nil ? recordings.count : nil)
            selectDefaultRecordingIfNeeded()
            await refreshLocalSessionLinks()
            lastSuccessfulRefreshAt = Date()
            isShowingCachedData = false
            cacheWarningMessage = nil
            state = recordings.isEmpty ? .empty : .loaded
            seedFailedRecordingJobPlaceholdersIfNeeded()
            await persistCacheSnapshot()
        } catch {
            if let apiError = error as? RecappiAPIError, apiError == .unauthorized {
                handleRefreshFailure(error, preserveVisibleData: hasVisibleLibraryData)
            } else {
                DiagnosticsLog.error(
                    "cloud",
                    "load_more.failed cursorHash=\(cursor.hashValue) \(DiagnosticsLog.errorSummary(error))"
                )
                cacheWarningMessage = "Load more failed · Current list kept"
                state = recordings.isEmpty ? .empty : .loaded
            }
        }

        isLoadingMore = false
    }


}
