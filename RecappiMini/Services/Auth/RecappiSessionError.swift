import Foundation

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
            return "Sign-in finished, but Recappi Cloud did not return a usable session. Reconnect and try again."
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

