import AppKit
import Foundation

@MainActor
extension CloudLibraryStore {
    func openBillingPortalOrPlans() async {
        guard await prepareForAuthenticatedRequest() else {
            openPlansPage()
            return
        }
        isOpeningBilling = true
        billingErrorMessage = nil

        do {
            let response = try await runAuthorized { client in
                try await client.createBillingPortalSession()
            }
            openURLString(response.url, fallback: plansURL)
        } catch let error as RecappiAPIError {
            switch error {
            case .unauthorized:
                apply(error: error)
            case .http(let statusCode, _) where statusCode == 409:
                // Free-tier accounts do not have a Stripe customer yet.
                openPlansPage()
            default:
                DiagnosticsLog.error("cloud", "billing.portal.failed \(DiagnosticsLog.errorSummary(error))")
                billingErrorMessage = NetworkErrorPresenter.userFacingMessage(for: error)
                openPlansPage()
            }
        } catch {
            DiagnosticsLog.error("cloud", "billing.portal.failed \(DiagnosticsLog.errorSummary(error))")
            billingErrorMessage = NetworkErrorPresenter.userFacingMessage(for: error)
            openPlansPage()
        }

        isOpeningBilling = false
    }

    func openPlansPage() {
        openURLString(plansURL.absoluteString, fallback: plansURL)
    }

    func deleteSelectedRecording() async {
        guard let recording = selectedRecording else { return }
        isDeleting = true
        defer { isDeleting = false }

        guard !recording.isLocalOnlyRecording else {
            DiagnosticsLog.event("cloud", "recording.delete.local recordingID=\(recording.id)")
            removeLocalProcessingRecording(id: recording.id)
            await persistCacheSnapshot()
            return
        }

        do {
            try await runAuthorized { client in
                try await client.deleteRecording(id: recording.id)
            }
            recordings.removeAll { $0.id == recording.id }
            transcriptCache.removeValue(forKey: recording.id)
            transcriptCacheRecordingUpdatedAt.removeValue(forKey: recording.id)
            transcriptionJobsByRecordingID.removeValue(forKey: recording.id)
            recordingIDsWithNewerVersions.remove(recording.id)
            playbackAudioURLsByRecordingID.removeValue(forKey: recording.id)
            if selectedRecordingID == recording.id {
                selectedRecordingID = recordings.first?.id
            }
            state = recordings.isEmpty ? .empty : .loaded
            await persistCacheSnapshot()
        } catch {
            if let apiError = error as? RecappiAPIError, apiError == .unauthorized {
                handleRefreshFailure(error, preserveVisibleData: hasVisibleLibraryData)
            } else {
                DiagnosticsLog.error(
                    "cloud",
                    "recording.delete.failed recordingID=\(recording.id) \(DiagnosticsLog.errorSummary(error))"
                )
                cacheWarningMessage = "Delete failed · Current list kept"
                state = recordings.isEmpty ? .empty : .loaded
            }
        }
    }

    func signIn(with provider: OAuthProvider) async {
        do {
            _ = try await sessionStore.startOAuth(provider: provider, origin: config.effectiveBackendBaseURL)
            await refresh()
        } catch {
            apply(error: error)
        }
    }

    func reconnect() async {
        do {
            _ = try await sessionStore.reconnect(origin: config.effectiveBackendBaseURL)
            await refresh()
        } catch {
            apply(error: error)
        }
    }

    func prepareForAuthenticatedRequest() async -> Bool {
        guard sessionStore.currentSession != nil || sessionStore.bearerToken() != nil else {
            state = .signedOut
            return false
        }
        return true
    }

    func runAuthorized<T>(
        _ operation: (RecappiAPIClient) async throws -> T
    ) async throws -> T {
        let origin = config.effectiveBackendBaseURL
        _ = try await sessionStore.ensureAuthorized(origin: origin)
        guard let token = sessionStore.bearerToken() else {
            throw RecappiSessionError.notSignedIn
        }

        do {
            let client = RecappiAPIClient(origin: origin, bearerToken: token)
            return try await operation(client)
        } catch let error as RecappiAPIError where error == .unauthorized {
            _ = try await sessionStore.handleUnauthorized(origin: origin)
            guard let refreshedToken = sessionStore.bearerToken() else {
                throw RecappiSessionError.notSignedIn
            }
            let refreshedClient = RecappiAPIClient(origin: origin, bearerToken: refreshedToken)
            return try await operation(refreshedClient)
        }
    }

    var plansURL: URL {
        URL(string: config.effectiveBackendBaseURL + "/plans") ?? URL(string: "https://recordmeet.ing/plans")!
    }

    func openURLString(_ raw: String, fallback: URL) {
        guard let url = URL(string: raw) else {
            NSWorkspace.shared.open(fallback)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func apply(error: Error) {
        if let apiError = error as? RecappiAPIError, apiError == .unauthorized {
            state = .expired
            cacheWarningMessage = nil
            return
        }
        if let sessionError = error as? RecappiSessionError {
            switch sessionError {
            case .notSignedIn:
                state = .signedOut
                cacheWarningMessage = nil
                return
            default:
                break
            }
        }
        state = .failed(NetworkErrorPresenter.userFacingMessage(for: error))
        cacheWarningMessage = nil
        DiagnosticsLog.error("cloud", "state.failed \(DiagnosticsLog.errorSummary(error))")
    }


}
