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

    private let cachedUserKey = "recappi.cachedUserSession"
    private let backendOriginKey = "recappi.backendOrigin"
    private let lastVerifiedKey = "recappi.lastVerifiedAt"
    private let lastProviderKey = "recappi.lastOAuthProvider"

    private init() {
        if let data = defaults.data(forKey: cachedUserKey),
           let session = try? JSONDecoder().decode(UserSession.self, from: data),
           keychain.readBearerToken() != nil {
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
        guard UITestModeConfiguration.shared.isEnabled else { return }

        let origin = AppConfig.shared.effectiveBackendBaseURL
        let hasInjectedAuth = UITestModeConfiguration.shared.authToken != nil

        if hasInjectedAuth {
            _ = keychain.deleteBearerToken()
            defaults.removeObject(forKey: cachedUserKey)
            defaults.removeObject(forKey: lastVerifiedKey)
            authStatus = .signedOut
            authStatusDetail = nil
            authFlowPhase = nil
        }

        if let authToken = UITestModeConfiguration.shared.authToken,
           let normalized = Self.normalizeBearerToken(authToken) {
            _ = keychain.saveBearerToken(normalized)
        }

        guard keychain.readBearerToken() != nil else { return }

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
        guard let bearerToken = keychain.readBearerToken() else {
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
                authStatus = .failed
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
            authStatus = .failed
            authStatusDetail = error.localizedDescription
            authFlowPhase = nil
            throw error
        }
    }

    func handleUnauthorized(origin: String) async throws -> UserSession {
        authStatus = .expired
        authStatusDetail = RecappiAPIError.unauthorized.localizedDescription
        authFlowPhase = nil
        _ = keychain.deleteBearerToken()
        defaults.removeObject(forKey: cachedUserKey)
        defaults.removeObject(forKey: lastVerifiedKey)

        if UITestModeConfiguration.shared.isEnabled {
            throw RecappiSessionError.reauthenticationUnavailableInUITests
        }

        return try await reconnect(origin: origin)
    }

    func bearerToken() -> String? {
        keychain.readBearerToken()
    }

    func signOut(origin: String) async {
        let resolvedOrigin = Self.normalizeOrigin(origin)
        authFlowPhase = .signingOut
        authStatusDetail = nil

        if let bearerToken = keychain.readBearerToken() {
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
        _ = keychain.deleteBearerToken()
        defaults.removeObject(forKey: cachedUserKey)
        defaults.removeObject(forKey: backendOriginKey)
        defaults.removeObject(forKey: lastVerifiedKey)
        authStatus = .signedOut
        authStatusDetail = nil
        authFlowPhase = nil
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
        _ = keychain.saveBearerToken(bearerToken)
        defaults.set(origin, forKey: backendOriginKey)
        defaults.set(Date().timeIntervalSince1970, forKey: lastVerifiedKey)
        if let provider {
            defaults.set(provider.rawValue, forKey: lastProviderKey)
        }
        if let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: cachedUserKey)
        }
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

enum RecappiSessionError: LocalizedError {
    case invalidBearerFormat
    case invalidSession
    case notSignedIn
    case oauthCancelled
    case oauthCallbackMismatch
    case oauthCallbackMissingCode
    case oauthExchangeExpired
    case oauthExchangeMissingToken
    case oauthVerifierMismatch
    case oauthPKCEGenerationFailed
    case oauthStartRejected(String)
    case oauthStartFailed
    case reauthenticationUnavailableInUITests

    var errorDescription: String? {
        switch self {
        case .invalidBearerFormat:
            return "Paste a bearer token or full Authorization header."
        case .invalidSession:
            return "Recappi Cloud rejected this sign-in. Reconnect and try again."
        case .notSignedIn:
            return "Sign in to Recappi Cloud in Settings before processing this recording."
        case .oauthCancelled:
            return "Recappi Cloud sign-in did not finish. If you closed the browser sheet or saw an error page there, retry."
        case .oauthCallbackMismatch:
            return "Recappi Cloud sign-in returned to an unexpected callback."
        case .oauthCallbackMissingCode:
            return "Recappi Cloud sign-in finished, but the callback did not include an exchange code."
        case .oauthExchangeExpired:
            return "Recappi Cloud sign-in expired before the app could finish exchanging the bridge code. Retry the login flow."
        case .oauthExchangeMissingToken:
            return "Recappi Cloud sign-in finished, but the bridge did not return a reusable bearer token."
        case .oauthVerifierMismatch:
            return "Recappi Cloud rejected the login challenge. Retry the sign-in flow."
        case .oauthPKCEGenerationFailed:
            return "Recappi Cloud sign-in could not prepare a secure login challenge."
        case .oauthStartRejected(let message):
            return "Recappi Cloud refused to start sign-in: \(message)"
        case .oauthStartFailed:
            return "Recappi Cloud sign-in could not start."
        case .reauthenticationUnavailableInUITests:
            return "UI-test auth token expired. Seed a fresh bearer token and rerun the flow."
        }
    }
}

private struct KeychainAuthStore {
    private let service = "com.recappi.mini"
    private let account = "recappi.auth-token"

    func readBearerToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    func saveBearerToken(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        var addQuery = baseQuery
        attributes.forEach { addQuery[$0.key] = $0.value }
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    func deleteBearerToken() -> Bool {
        SecItemDelete(baseQuery as CFDictionary) == errSecSuccess
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
