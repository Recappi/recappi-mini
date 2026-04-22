import Foundation

struct UserSession: Equatable, Codable, Sendable {
    let userId: String
    let email: String
    let name: String
    let imageURL: String?
    let expiresAt: String
    let backendOrigin: String
}

enum AuthStatus: Equatable {
    case signedOut
    case authenticating
    case signedIn(UserSession)
    case expired
    case failed
}

enum AuthFlowPhase: Equatable {
    case starting(provider: OAuthProvider)
    case awaitingUserInteraction(provider: OAuthProvider)
    case exchangingCode(provider: OAuthProvider)
    case verifyingSession(provider: OAuthProvider?)
    case signingOut

    var activeProvider: OAuthProvider? {
        switch self {
        case .starting(let provider),
                .awaitingUserInteraction(let provider),
                .exchangingCode(let provider):
            return provider
        case .verifyingSession(let provider):
            return provider
        case .signingOut:
            return nil
        }
    }

    var statusText: String {
        switch self {
        case .starting(let provider):
            return "Starting \(provider.displayName) sign-in…"
        case .awaitingUserInteraction(let provider):
            return "Continue with \(provider.displayName) in the secure browser sheet."
        case .exchangingCode(let provider):
            return "Finishing \(provider.displayName) sign-in with Recappi Cloud…"
        case .verifyingSession(let provider):
            if let provider {
                return "Refreshing your \(provider.displayName) session…"
            }
            return "Refreshing your Recappi Cloud session…"
        case .signingOut:
            return "Signing out of Recappi Cloud…"
        }
    }

    var buttonLabel: String {
        switch self {
        case .starting:
            return "Preparing…"
        case .awaitingUserInteraction:
            return "Continue in browser…"
        case .exchangingCode:
            return "Finishing…"
        case .verifyingSession:
            return "Verifying…"
        case .signingOut:
            return "Signing out…"
        }
    }
}

enum OAuthProvider: String, CaseIterable, Identifiable, Sendable {
    case google
    case github

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google:
            return "Google"
        case .github:
            return "GitHub"
        }
    }
}

enum ProcessingProgressStyle: Equatable {
    case determinate(Double)
    case indeterminate(base: Double)
}

enum ProcessingPhase: Equatable {
    case savingAudio
    case preparingUploadWav
    case verifyingSession
    case creatingRecording
    case uploading(progress: Double)
    case completingUpload
    case startingTranscription
    case polling(jobStatus: String)
    case fetchingTranscript

    var title: String {
        switch self {
        case .savingAudio: return "Saving audio…"
        case .preparingUploadWav: return "Preparing upload audio…"
        case .verifyingSession: return "Verifying session…"
        case .creatingRecording: return "Creating recording…"
        case .uploading: return "Uploading…"
        case .completingUpload: return "Completing upload…"
        case .startingTranscription: return "Starting transcription…"
        case .polling: return "Transcribing…"
        case .fetchingTranscript: return "Fetching transcript…"
        }
    }

    var detail: String {
        switch self {
        case .savingAudio:
            return "Preparing local session"
        case .preparingUploadWav:
            return "Converting recording.m4a to upload.wav"
        case .verifyingSession:
            return "Checking Recappi Cloud session"
        case .creatingRecording:
            return "Creating remote recording"
        case .uploading(let progress):
            let percent = Int((progress * 100).rounded())
            return "Uploading \(max(0, min(100, percent)))%"
        case .completingUpload:
            return "Committing uploaded parts"
        case .startingTranscription:
            return "Submitting ASR job"
        case .polling(let jobStatus):
            return "Job: \(jobStatus) · waiting on backend"
        case .fetchingTranscript:
            return "Downloading text"
        }
    }

    var progressValue: Double? {
        if case .uploading(let progress) = self { return progress }
        return nil
    }

    var progressStyle: ProcessingProgressStyle {
        switch self {
        case .savingAudio:
            return .determinate(0.08)
        case .preparingUploadWav:
            return .determinate(0.16)
        case .verifyingSession:
            return .determinate(0.24)
        case .creatingRecording:
            return .determinate(0.34)
        case .uploading(let progress):
            let clamped = max(0, min(1, progress))
            return .determinate(0.34 + (0.34 * clamped))
        case .completingUpload:
            return .determinate(0.72)
        case .startingTranscription:
            return .determinate(0.8)
        case .polling:
            return .indeterminate(base: 0.82)
        case .fetchingTranscript:
            return .determinate(0.96)
        }
    }
}

struct RemoteSessionManifest: Codable, Equatable {
    var recordingId: String?
    var jobId: String?
    var transcriptId: String?
    var stage: String
    var errorMessage: String?
    var uploadFilename: String?
    var provider: String?
    var model: String?
    var updatedAt: String

    static func stage(_ stage: String) -> RemoteSessionManifest {
        RemoteSessionManifest(
            recordingId: nil,
            jobId: nil,
            transcriptId: nil,
            stage: stage,
            errorMessage: nil,
            uploadFilename: nil,
            provider: nil,
            model: nil,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }
}
