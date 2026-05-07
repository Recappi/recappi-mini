import Foundation
import Security

@MainActor
final class AuthSessionStore: ObservableObject {
    static let shared = AuthSessionStore()

    @Published private(set) var authStatus: AuthStatus
    @Published private(set) var authStatusDetail: String?
    @Published private(set) var authFlowPhase: AuthFlowPhase?

    private let defaults = UserDefaults.standard
    private let keychain = KeychainAuthStore()
    private let developmentStore = DevelopmentAuthStore()
    private let uiTestMode = UITestModeConfiguration.shared
    private var uiTestBearerToken: String?

    private let cachedUserKey = "recappi.cachedUserSession"
    private let backendOriginKey = "recappi.backendOrigin"
    private let lastVerifiedKey = "recappi.lastVerifiedAt"
    private let lastProviderKey = "recappi.lastOAuthProvider"

    private init() {
        let hasPersistedToken: Bool
        if uiTestMode.isEnabled {
            hasPersistedToken = false
        } else if Self.prefersDevelopmentFileStore {
            hasPersistedToken = developmentStore.readBearerToken() != nil
        } else {
            hasPersistedToken = keychain.readBearerToken() != nil
        }
        if let data = defaults.data(forKey: cachedUserKey),
           let session = try? JSONDecoder().decode(UserSession.self, from: data),
           hasPersistedToken {
            authStatus = .signedIn(session)
            authStatusDetail = nil
            authFlowPhase = nil
        } else {
            authStatus = .signedOut
            authStatusDetail = nil
            authFlowPhase = nil
        }
    }

    var currentSession: UserSession? {
        if case .signedIn(let session) = authStatus { return session }
        return nil
    }

    var backendOrigin: String? {
        defaults.string(forKey: backendOriginKey)
    }

    var lastOAuthProvider: OAuthProvider? {
        defaults.string(forKey: lastProviderKey).flatMap(OAuthProvider.init(rawValue:))
    }

    var isAuthBusy: Bool {
        authFlowPhase != nil || authStatus == .authenticating
    }

    func bootstrapForUITestsIfNeeded() async {
        guard uiTestMode.isEnabled else { return }

        let origin = AppConfig.shared.effectiveBackendBaseURL
        let hasInjectedAuth = uiTestMode.authToken != nil

        if hasInjectedAuth {
            _ = deletePersistedBearerToken()
            defaults.removeObject(forKey: cachedUserKey)
            defaults.removeObject(forKey: lastVerifiedKey)
            authStatus = .signedOut
            authStatusDetail = nil
            authFlowPhase = nil
        }

        if let authToken = uiTestMode.authToken,
           let normalized = Self.normalizeBearerToken(authToken) {
            _ = savePersistedBearerToken(normalized)
        }

        guard readPersistedBearerToken() != nil else { return }

        do {
            _ = try await ensureAuthorized(origin: origin)
        } catch {
            // Keep the seeded credential around so UI tests can intentionally
            // cover invalid / expired token states without surprise mutation.
        }
    }

    func startOAuth(provider: OAuthProvider, origin: String) async throws -> UserSession {
        beginAuthentication(.starting(provider: provider))
        let resolvedOrigin = Self.normalizeOrigin(origin)
        do {
            let bootstrap = try await NativeOAuthCoordinator().authenticate(
                provider: provider,
                origin: resolvedOrigin
            ) { phase in
                self.authFlowPhase = phase
            }
            persist(
                bearerToken: bootstrap.bearerToken,
                session: bootstrap.session,
                origin: resolvedOrigin,
                provider: provider
            )
            authStatus = .signedIn(bootstrap.session)
            authStatusDetail = nil
            authFlowPhase = nil
            return bootstrap.session
        } catch {
            if let apiError = error as? RecappiAPIError, apiError == .unauthorized {
                authStatus = .expired
            } else {
                NSLog("[Recappi] auth.startOAuth: catch_all -> .failed type=\(String(describing: type(of: error)))")
                authStatus = .failed
            }
            authStatusDetail = error.localizedDescription
            authFlowPhase = nil
            throw error
        }
    }

    func importBearerToken(_ raw: String, origin: String) async throws -> UserSession {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = Self.normalizeBearerToken(cleaned) else {
            authStatus = .failed
            authStatusDetail = RecappiSessionError.invalidBearerFormat.localizedDescription
            authFlowPhase = nil
            throw RecappiSessionError.invalidBearerFormat
        }

        beginAuthentication(.verifyingSession(provider: nil))
        let resolvedOrigin = Self.normalizeOrigin(origin)
        let client = RecappiAPIClient(origin: resolvedOrigin, bearerToken: normalized)

        do {
            let lookup = try await client.getSession()
            guard let session = lookup.userSession else {
                discardPersistedCredentialStorage()
                authStatus = .failed
                throw RecappiSessionError.invalidSession
            }

            persist(
                bearerToken: lookup.bearerToken ?? normalized,
                session: session,
                origin: resolvedOrigin,
                provider: lastOAuthProvider
            )
            authStatus = .signedIn(session)
            authStatusDetail = nil
            authFlowPhase = nil
            return session
        } catch let error as RecappiAPIError where error == .unauthorized {
            authStatus = .expired
            authStatusDetail = error.localizedDescription
            authFlowPhase = nil
            throw error
        } catch {
            authStatus = .failed
            authStatusDetail = error.localizedDescription
            authFlowPhase = nil
            throw error
        }
    }

    func reconnect(origin: String) async throws -> UserSession {
        let provider = lastOAuthProvider ?? .google
        return try await startOAuth(provider: provider, origin: origin)
    }

    func ensureAuthorized(origin: String) async throws -> UserSession {
        guard let bearerToken = readPersistedBearerToken() else {
            authStatus = .signedOut
            authStatusDetail = nil
            authFlowPhase = nil
            throw RecappiSessionError.notSignedIn
        }

        let resolvedOrigin = Self.normalizeOrigin(origin)
        let client = RecappiAPIClient(origin: resolvedOrigin, bearerToken: bearerToken)

        do {
            let lookup = try await client.getSession()
            guard let session = lookup.userSession else {
                // Server responded but did not return a session. Treat this
                // as `.expired` (token effectively no good) rather than
                // `.failed` — same semantic as a real 401, no need to flip
                // the chip to "Needs attention" while the user is just
                // browsing recordings.
                NSLog("[Recappi] auth.ensureAuthorized: nil_userSession -> .expired")
                discardPersistedCredentialStorage()
                authStatus = .expired
                authStatusDetail = RecappiAPIError.unauthorized.localizedDescription
                throw RecappiSessionError.invalidSession
            }

            persist(
                bearerToken: lookup.bearerToken ?? bearerToken,
                session: session,
                origin: resolvedOrigin,
                provider: lastOAuthProvider
            )
            authStatus = .signedIn(session)
            authStatusDetail = nil
            authFlowPhase = nil
            return session
        } catch let error as RecappiAPIError where error == .unauthorized {
            authStatus = .expired
            authStatusDetail = error.localizedDescription
            authFlowPhase = nil
            throw error
        } catch {
            // Transient network errors (timeout, 5xx, offline, DNS, etc.)
            // should NOT poison `authStatus`. The user is still validly
            // signed in — the request just failed. Flipping the status to
            // `.failed` here causes the email chip to bounce to "Needs
            // attention" on benign hiccups (e.g. selecting a recording
            // while WiFi is flaky), confusing users into re-signing in.
            //
            // We still throw so the caller (CloudLibraryStore) can surface
            // a cache-warning banner at its own layer, which is the right
            // semantic for "transient request failure".
            NSLog("[Recappi] auth.ensureAuthorized: transient_error type=\(String(describing: type(of: error))) -> auth_status_unchanged")
            authStatusDetail = error.localizedDescription
            authFlowPhase = nil
            throw error
        }
    }

    func handleUnauthorized(origin: String) async throws -> UserSession {
        authStatus = .expired
        authStatusDetail = RecappiAPIError.unauthorized.localizedDescription
        authFlowPhase = nil
        _ = deletePersistedBearerToken()
        defaults.removeObject(forKey: cachedUserKey)
        defaults.removeObject(forKey: lastVerifiedKey)

        if uiTestMode.isEnabled {
            throw RecappiSessionError.reauthenticationUnavailableInUITests
        }

        return try await reconnect(origin: origin)
    }

    func bearerToken() -> String? {
        readPersistedBearerToken()
    }

    func signOut(origin: String) async {
        let resolvedOrigin = Self.normalizeOrigin(origin)
        authFlowPhase = .signingOut
        authStatusDetail = nil

        if let bearerToken = readPersistedBearerToken() {
            let client = RecappiAPIClient(origin: resolvedOrigin, bearerToken: bearerToken)
            do {
                try await client.signOut()
            } catch let error as RecappiAPIError where error == .unauthorized {
                // Treat an already-expired token as signed out and continue clearing local state.
            } catch {
                // Remote revocation is best-effort; local sign-out still wins.
                NSLog("[Recappi] signOut remote revoke failed: \(error.localizedDescription)")
            }
        }

        clearSession()
    }

    func clearSession() {
        discardPersistedCredentialStorage()
        defaults.removeObject(forKey: backendOriginKey)
        authStatus = .signedOut
        authStatusDetail = nil
        authFlowPhase = nil
    }

    private func discardPersistedCredentialStorage() {
        _ = deletePersistedBearerToken()
        defaults.removeObject(forKey: cachedUserKey)
        defaults.removeObject(forKey: lastVerifiedKey)
    }

    private func beginAuthentication(_ phase: AuthFlowPhase) {
        authStatus = .authenticating
        authStatusDetail = nil
        authFlowPhase = phase
    }

    private func persist(
        bearerToken: String,
        session: UserSession,
        origin: String,
        provider: OAuthProvider?
    ) {
        _ = savePersistedBearerToken(bearerToken)
        defaults.set(origin, forKey: backendOriginKey)
        defaults.set(Date().timeIntervalSince1970, forKey: lastVerifiedKey)
        if let provider {
            defaults.set(provider.rawValue, forKey: lastProviderKey)
        }
        if let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: cachedUserKey)
        }
    }

    private func readPersistedBearerToken() -> String? {
        if uiTestMode.isEnabled {
            return uiTestBearerToken
        }
        if Self.prefersDevelopmentFileStore {
            return developmentStore.readBearerToken()
        }
        return keychain.readBearerToken()
    }

    private func savePersistedBearerToken(_ value: String) -> Bool {
        if uiTestMode.isEnabled {
            uiTestBearerToken = value
            return true
        }
        if Self.prefersDevelopmentFileStore {
            return developmentStore.saveBearerToken(value)
        }
        return keychain.saveBearerToken(value)
    }

    private func deletePersistedBearerToken() -> Bool {
        if uiTestMode.isEnabled {
            let hadValue = uiTestBearerToken != nil
            uiTestBearerToken = nil
            return hadValue
        }
        if Self.prefersDevelopmentFileStore {
            return developmentStore.deleteBearerToken()
        }
        return keychain.deleteBearerToken()
    }

    private static var prefersDevelopmentFileStore: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["RECAPPI_USE_KEYCHAIN_AUTH"] != "1"
        #else
        return ProcessInfo.processInfo.environment["RECAPPI_USE_FILE_AUTH_STORAGE"] == "1"
        #endif
    }

    nonisolated static func normalizeOrigin(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    nonisolated static func normalizeBearerToken(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("bearer ") {
            let suffix = trimmed.dropFirst("Bearer ".count)
            let value = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        if trimmed.lowercased().hasPrefix("set-auth-token:") {
            let suffix = trimmed.dropFirst("set-auth-token:".count)
            let value = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        return trimmed
    }

}
