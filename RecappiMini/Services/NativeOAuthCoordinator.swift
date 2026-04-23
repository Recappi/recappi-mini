import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

struct AuthBootstrap: Equatable {
    let session: UserSession
    let bearerToken: String
}

private struct PKCEChallenge: Equatable {
    let verifier: String
    let challenge: String
}

@MainActor
final class NativeOAuthCoordinator: NSObject {
    nonisolated static let callbackScheme = "recappi"
    nonisolated static let callbackHost = "auth"
    nonisolated static let callbackPath = "/callback"
    nonisolated static let bridgePath = "/api/native-oauth-bridge"
    nonisolated static let loginPath = "/login"

    private var webAuthenticationSession: ASWebAuthenticationSession?
    private var webAuthenticationRelay: WebAuthenticationCompletionRelay?
    private var completionBridge: CheckedContinuation<URL, Error>?

    func authenticate(
        provider: OAuthProvider,
        origin: String,
        updatePhase: @escaping @MainActor @Sendable (AuthFlowPhase) -> Void
    ) async throws -> AuthBootstrap {
        let client = RecappiAuthBootstrapClient(origin: origin)
        let challenge = try Self.makePKCEChallenge()
        let authorizeURL = try Self.nativeLoginKickoffURL(
            origin: origin,
            provider: provider,
            challenge: challenge.challenge
        )
        updatePhase(.awaitingUserInteraction(provider: provider))
        NSApp.activate(ignoringOtherApps: true)

        let callbackURL = try await startWebAuthenticationSession(
            url: authorizeURL,
            callbackURLScheme: Self.callbackScheme
        )
        webAuthenticationSession = nil

        let code = try Self.extractExchangeCode(from: callbackURL)
        updatePhase(.exchangingCode(provider: provider))
        return try await client.exchangeCode(code: code, verifier: challenge.verifier) {
            updatePhase(.verifyingSession(provider: provider))
        }
    }

    nonisolated static func bridgeCallbackURL(origin: String, challenge: String) throws -> String {
        let trimmedOrigin = origin.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard var components = URLComponents(string: trimmedOrigin + bridgePath) else {
            throw RecappiAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "challenge", value: challenge)]
        guard let url = components.url else {
            throw RecappiAPIError.invalidURL
        }
        return url.absoluteString
    }

    nonisolated static func nativeLoginKickoffURL(
        origin: String,
        provider: OAuthProvider,
        challenge: String
    ) throws -> URL {
        let bridgeCallbackURL = try bridgeCallbackURL(origin: origin, challenge: challenge)
        let trimmedOrigin = origin.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard var components = URLComponents(string: trimmedOrigin + loginPath) else {
            throw RecappiAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "native", value: "1"),
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "callbackURL", value: bridgeCallbackURL),
            URLQueryItem(name: "errorCallbackURL", value: bridgeCallbackURL),
        ]
        guard let url = components.url else {
            throw RecappiAPIError.invalidURL
        }
        return url
    }

    nonisolated static func extractExchangeCode(from callbackURL: URL) throws -> String {
        guard callbackURL.scheme?.lowercased() == callbackScheme,
              callbackURL.host?.lowercased() == callbackHost,
              callbackURL.path == callbackPath else {
            throw RecappiSessionError.oauthCallbackMismatch
        }

        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let code = components?.queryItems?.first(where: { $0.name == "code" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let code, !code.isEmpty else {
            throw RecappiSessionError.oauthCallbackMissingCode
        }

        return code
    }

    private func startWebAuthenticationSession(
        url: URL,
        callbackURLScheme: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            completionBridge = continuation
            let relay = WebAuthenticationCompletionRelay(coordinator: self)
            webAuthenticationRelay = relay

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme,
                completionHandler: relay.makeHandler()
            )

            session.presentationContextProvider = self
            // Keep the native sign-in sheet isolated from the user's Safari
            // session. The backend's `/login?native=1` route currently redirects
            // already-signed-in web sessions to `/`, which strands the flow on
            // the website instead of reaching the native OAuth bridge.
            session.prefersEphemeralWebBrowserSession = true
            webAuthenticationSession = session

            if session.start() {
                return
            }

            webAuthenticationSession = nil
            webAuthenticationRelay = nil
            completionBridge = nil
            continuation.resume(throwing: RecappiSessionError.oauthStartFailed)
        }
    }

    fileprivate func finishWebAuthenticationSession(callbackURL: URL?, error: Error?) {
        webAuthenticationSession = nil
        webAuthenticationRelay = nil
        let bridge = completionBridge
        completionBridge = nil

        if let error {
            bridge?.resume(throwing: Self.mapAuthenticationError(error))
            return
        }

        guard let callbackURL else {
            bridge?.resume(throwing: RecappiSessionError.oauthCallbackMismatch)
            return
        }

        bridge?.resume(returning: callbackURL)
    }

    private static func mapAuthenticationError(_ error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain == ASWebAuthenticationSessionErrorDomain else {
            return error
        }

        if nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
            return RecappiSessionError.oauthCancelled
        }

        return error
    }

    private nonisolated static func makePKCEChallenge() throws -> PKCEChallenge {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw RecappiSessionError.oauthPKCEGenerationFailed
        }

        let verifierData = Data(bytes)
        let verifier = base64URLEncode(verifierData)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncode(Data(digest))
        return PKCEChallenge(verifier: verifier, challenge: challenge)
    }

    private nonisolated static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class WebAuthenticationCompletionRelay {
    weak var coordinator: NativeOAuthCoordinator?

    init(coordinator: NativeOAuthCoordinator) {
        self.coordinator = coordinator
    }

    nonisolated func makeHandler() -> (URL?, Error?) -> Void {
        { [weak coordinator = self.coordinator] callbackURL, error in
            Task { @MainActor [weak coordinator] in
                coordinator?.finishWebAuthenticationSession(callbackURL: callbackURL, error: error)
            }
        }
    }
}

extension NativeOAuthCoordinator: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let keyWindow = NSApp.keyWindow {
            return keyWindow
        }
        if let firstWindow = NSApp.windows.first {
            return firstWindow
        }
        return NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }
}

struct RecappiAuthBootstrapClient: Sendable {
    let origin: String
    let session: URLSession

    init(origin: String, session: URLSession = RecappiNetworking.bearerSession) {
        self.origin = origin.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        self.session = session
    }

    func exchangeCode(
        code: String,
        verifier: String,
        beforeSessionLookup: @escaping @MainActor @Sendable () -> Void
    ) async throws -> AuthBootstrap {
        var request = try makeRequest(path: "/api/native-oauth-bridge/exchange")
        request.timeoutInterval = 180
        request.httpBody = try JSONEncoder().encode(NativeOAuthExchangeRequest(code: code, verifier: verifier))

        let (data, response) = try await session.data(for: request)
        do {
            try Self.validate(response: response, data: data)
        } catch let error as RecappiAPIError {
            throw Self.mapExchangeError(error)
        }
        let payload = try JSONDecoder().decode(NativeOAuthExchangeResponse.self, from: data)

        guard let normalizedToken = AuthSessionStore.normalizeBearerToken(payload.token) else {
            throw RecappiSessionError.oauthExchangeMissingToken
        }

        await MainActor.run {
            beforeSessionLookup()
        }
        let lookup = try await RecappiAPIClient(origin: origin, bearerToken: normalizedToken, session: session).getSession()
        guard let userSession = lookup.userSession else {
            throw RecappiSessionError.invalidSession
        }

        return AuthBootstrap(
            session: userSession,
            bearerToken: lookup.bearerToken ?? normalizedToken
        )
    }

    private func makeRequest(path: String) throws -> URLRequest {
        guard let url = URL(string: origin + path) else {
            throw RecappiAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RecappiAPIError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            throw RecappiAPIError.http(
                statusCode: http.statusCode,
                message: RecappiAPIClient.extractErrorMessage(from: data)
            )
        }
    }

    private static func mapExchangeError(_ error: RecappiAPIError) -> Error {
        switch error {
        case .http(let statusCode, let message):
            let lowercased = message.lowercased()
            if statusCode == 401, lowercased.contains("invalid or expired code") {
                return RecappiSessionError.oauthExchangeExpired
            }
            if statusCode == 403, lowercased.contains("verifier mismatch") {
                return RecappiSessionError.oauthVerifierMismatch
            }
            return error
        default:
            return error
        }
    }
}

private struct NativeOAuthExchangeRequest: Encodable {
    let code: String
    let verifier: String
}

private struct NativeOAuthExchangeResponse: Decodable {
    let token: String
}
