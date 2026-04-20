import Foundation
import Security

@MainActor
final class CookieSessionStore: ObservableObject {
    static let shared = CookieSessionStore()

    @Published private(set) var authStatus: AuthStatus

    private let defaults = UserDefaults.standard
    private let keychain = KeychainCookieStore()

    private let cachedUserKey = "recappi.cachedUserSession"
    private let backendOriginKey = "recappi.backendOrigin"
    private let lastVerifiedKey = "recappi.lastVerifiedAt"

    private init() {
        if let data = defaults.data(forKey: cachedUserKey),
           let session = try? JSONDecoder().decode(UserSession.self, from: data),
           keychain.readCookieValue() != nil {
            authStatus = .signedIn(session)
        } else {
            authStatus = .signedOut
        }
    }

    var currentSession: UserSession? {
        if case .signedIn(let session) = authStatus { return session }
        return nil
    }

    var backendOrigin: String? {
        defaults.string(forKey: backendOriginKey)
    }

    func bootstrapForUITestsIfNeeded() {
        guard UITestModeConfiguration.shared.isEnabled,
              let cookie = UITestModeConfiguration.shared.cookieValue,
              keychain.readCookieValue() == nil,
              let normalized = Self.normalizeCookieHeader(cookie) else {
            return
        }
        _ = keychain.saveCookieValue(normalized.value)
        defaults.set(AppConfig.shared.effectiveBackendBaseURL, forKey: backendOriginKey)
    }

    func verifySession(using input: String, origin: String) async throws -> UserSession {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = Self.normalizeCookieHeader(cleaned) else {
            authStatus = .invalidCookie
            throw RecappiSessionError.invalidCookieFormat
        }

        authStatus = .verifying
        let client = RecappiAPIClient(origin: origin, cookieValue: normalized.value)

        do {
            let session = try await client.getSession()
            guard let session else {
                authStatus = .invalidCookie
                throw RecappiSessionError.invalidCookie
            }
            persist(cookieValue: normalized.value, session: session, origin: origin)
            authStatus = .signedIn(session)
            return session
        } catch let error as RecappiAPIError {
            authStatus = error == .unauthorized ? .expired : .invalidCookie
            throw error
        } catch {
            authStatus = .invalidCookie
            throw error
        }
    }

    func ensureAuthorized(origin: String) async throws -> UserSession {
        guard let cookieValue = keychain.readCookieValue() else {
            authStatus = .signedOut
            throw RecappiSessionError.notSignedIn
        }

        let client = RecappiAPIClient(origin: origin, cookieValue: cookieValue)
        do {
            if let session = try await client.getSession() {
                persist(cookieValue: cookieValue, session: session, origin: origin)
                authStatus = .signedIn(session)
                return session
            }
            authStatus = .invalidCookie
            throw RecappiSessionError.invalidCookie
        } catch let error as RecappiAPIError where error == .unauthorized {
            authStatus = .expired
            throw error
        }
    }

    func cookieValue() -> String? {
        keychain.readCookieValue()
    }

    func clearSession() {
        _ = keychain.deleteCookieValue()
        defaults.removeObject(forKey: cachedUserKey)
        defaults.removeObject(forKey: backendOriginKey)
        defaults.removeObject(forKey: lastVerifiedKey)
        authStatus = .signedOut
    }

    private func persist(cookieValue: String, session: UserSession, origin: String) {
        _ = keychain.saveCookieValue(cookieValue)
        defaults.set(origin, forKey: backendOriginKey)
        defaults.set(Date().timeIntervalSince1970, forKey: lastVerifiedKey)
        if let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: cachedUserKey)
        }
    }

    nonisolated static func normalizeCookieHeader(_ raw: String) -> NormalizedCookieInput? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = extractCookie(named: "__Secure-better-auth.session_token", from: trimmed) {
            return NormalizedCookieInput(value: direct)
        }

        if let plain = extractCookie(named: "better-auth.session_token", from: trimmed) {
            return NormalizedCookieInput(value: plain)
        }

        if trimmed.contains("=") {
            return nil
        }

        return NormalizedCookieInput(value: trimmed)
    }

    private nonisolated static func extractCookie(named name: String, from header: String) -> String? {
        let pieces = header.split(separator: ";")
        for piece in pieces {
            let part = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "\(name)="
            if part.hasPrefix(prefix) {
                return String(part.dropFirst(prefix.count))
            }
        }
        return nil
    }

    struct NormalizedCookieInput {
        let value: String

        var header: String {
            "__Secure-better-auth.session_token=\(value)"
        }
    }
}

enum RecappiSessionError: LocalizedError {
    case invalidCookieFormat
    case invalidCookie
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .invalidCookieFormat:
            return "Paste a Better Auth session cookie or raw cookie value."
        case .invalidCookie:
            return "The session cookie is invalid or expired."
        case .notSignedIn:
            return "Sign in on recordmeet.ing and paste your session cookie in Settings."
        }
    }
}

private struct KeychainCookieStore {
    private let service = "com.recappi.mini"
    private let account = "recappi.session-cookie"

    func readCookieValue() -> String? {
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

    func saveCookieValue(_ value: String) -> Bool {
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

    func deleteCookieValue() -> Bool {
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
