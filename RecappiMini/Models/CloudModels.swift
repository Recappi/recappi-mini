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
    case summarizing

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
        case .summarizing: return "Summarizing…"
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
        case .summarizing:
            return "Generating notes locally"
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
            return .determinate(0.94)
        case .summarizing:
            return .determinate(0.98)
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
