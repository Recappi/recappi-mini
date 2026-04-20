import AppKit
import AuthenticationServices
import Foundation

struct AuthBootstrap: Equatable {
    let session: UserSession
    let bearerToken: String
}

@MainActor
final class NativeOAuthCoordinator: NSObject {
    private var webAuthenticationSession: ASWebAuthenticationSession?
    private var completionBridge: CheckedContinuation<URL, Error>?

    func authenticate(provider: OAuthProvider, origin: String) async throws -> AuthBootstrap {
        let client = RecappiAuthBootstrapClient(origin: origin)
        let authorizeURL = try await client.signInURL(provider: provider, callbackURL: origin + "/")
        let callback = try makeCallbackMatcher(from: authorizeURL)

        _ = try await startWebAuthenticationSession(url: authorizeURL, callback: callback)
        webAuthenticationSession = nil

        return try await client.exchangeSharedBrowserSession()
    }

    private func startWebAuthenticationSession(
        url: URL,
        callback: ASWebAuthenticationSession.Callback
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            completionBridge = continuation

            let session = ASWebAuthenticationSession(url: url, callback: callback) { [weak self] callbackURL, error in
                guard let self else { return }
                self.webAuthenticationSession = nil
                let bridge = self.completionBridge
                self.completionBridge = nil

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

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webAuthenticationSession = session

            if session.start() {
                return
            }

            webAuthenticationSession = nil
            completionBridge = nil
            continuation.resume(throwing: RecappiSessionError.oauthStartFailed)
        }
    }

    private func makeCallbackMatcher(from authorizeURL: URL) throws -> ASWebAuthenticationSession.Callback {
        guard let components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false),
              let redirectValue = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let redirectURL = URL(string: redirectValue),
              let host = redirectURL.host else {
            throw RecappiSessionError.oauthCallbackMismatch
        }

        let path = redirectURL.path.isEmpty ? "/" : redirectURL.path
        return .https(host: host, path: path)
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

    init(origin: String, session: URLSession = .shared) {
        self.origin = origin.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        self.session = session
    }

    func signInURL(provider: OAuthProvider, callbackURL: String) async throws -> URL {
        guard let url = URL(string: origin + "/api/auth/sign-in/social") else {
            throw RecappiAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SocialSignInRequest(provider: provider.rawValue, callbackURL: callbackURL))

        let (data, response) = try await session.data(for: request)
        try RecappiAPIClient.validate(response: response, data: data)
        let payload = try JSONDecoder().decode(SocialSignInResponse.self, from: data)

        guard let url = URL(string: payload.url) else {
            throw RecappiSessionError.oauthStartFailed
        }

        return url
    }

    func exchangeCookieForBearer(_ cookieValue: String) async throws -> AuthBootstrap {
        try await exchangeSession(using: .cookie(cookieValue))
    }

    func exchangeSharedBrowserSession() async throws -> AuthBootstrap {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true

        let sharedSession = URLSession(configuration: configuration)
        return try await exchangeSession(using: .browserCookies(sharedSession))
    }

    private func exchangeSession(using strategy: ExchangeStrategy) async throws -> AuthBootstrap {
        guard let url = URL(string: origin + "/api/auth/get-session") else {
            throw RecappiAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 180
        request.setValue(origin, forHTTPHeaderField: "Origin")

        let sessionToUse: URLSession
        switch strategy {
        case .cookie(let cookieValue):
            request.setValue("__Secure-better-auth.session_token=\(cookieValue)", forHTTPHeaderField: "Cookie")
            sessionToUse = session
        case .browserCookies(let sharedSession):
            sessionToUse = sharedSession
        }

        let (data, response) = try await sessionToUse.data(for: request)
        try RecappiAPIClient.validate(response: response, data: data)
        let lookup = try RecappiAPIClient.decodeSessionLookup(from: data, response: response, origin: origin)

        guard let session = lookup.userSession else {
            throw RecappiSessionError.invalidSession
        }
        guard let bearerToken = lookup.bearerToken else {
            throw RecappiSessionError.oauthExchangeMissingToken
        }

        return AuthBootstrap(session: session, bearerToken: bearerToken)
    }

    private enum ExchangeStrategy {
        case cookie(String)
        case browserCookies(URLSession)
    }
}

private struct SocialSignInRequest: Encodable {
    let provider: String
    let callbackURL: String
}

private struct SocialSignInResponse: Decodable {
    let url: String
    let redirect: Bool?
}
