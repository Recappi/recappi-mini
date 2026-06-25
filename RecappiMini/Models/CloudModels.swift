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
            // Keep this short enough to fit the fixed-width 168-pt OAuth
            // button without truncation. The longer "Continue in browser…"
            // string used to clip mid-word on the Cloud sign-in surface.
            return "Opening browser…"
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
        case .preparingUploadWav: return "Preparing fallback audio…"
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
            return "Preparing a WAV fallback for backend compatibility"
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
    // Account boundary for local recording sessions. Optional so legacy manifests
    // (written before account-scoping) decode as nil = "unattributed". The origin
    // matches CloudLibraryStore.cacheContext() (normalized effective backend URL),
    // NOT UserSession.backendOrigin, so local sessions partition identically to the
    // cloud cache.
    var accountUserId: String? = nil
    var accountBackendOrigin: String? = nil

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

    var hasTranscriptReference: Bool {
        guard let transcriptId = transcriptId?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !transcriptId.isEmpty
    }

    /// The account partition this session is stamped with, or nil when it is
    /// unattributed. Both fields must be present and non-empty together; a partial
    /// stamp is treated as unattributed (and the scanner logs a diagnostic), per
    /// the storage contract guardrail.
    var attributedAccount: (userId: String, backendOrigin: String)? {
        guard let userId = accountUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
              let origin = accountBackendOrigin?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userId.isEmpty, !origin.isEmpty else {
            return nil
        }
        return (userId, origin)
    }

    /// True when this session carries no usable account stamp (legacy, signed-out,
    /// or partial). Hidden from every account's view until explicitly claimed.
    var isAccountUnattributed: Bool { attributedAccount == nil }

    /// True only when exactly one of the account fields is set — an inconsistent
    /// stamp that we surface as a diagnostic rather than trusting.
    var hasPartialAccountStamp: Bool {
        let hasUser = !(accountUserId?.isEmpty ?? true)
        let hasOrigin = !(accountBackendOrigin?.isEmpty ?? true)
        return hasUser != hasOrigin
    }

    /// Whether this session belongs to the given account partition. Unattributed
    /// or partially-stamped sessions never match, so they cannot leak across
    /// accounts.
    func belongsToAccount(userId: String, backendOrigin: String) -> Bool {
        guard let account = attributedAccount else { return false }
        return account.userId == userId && account.backendOrigin == backendOrigin
    }
}

struct RecordingSessionMetadata: Codable, Equatable, Sendable {
    var summaryTitle: String?
    var sourceTitle: String
    var sourceAppName: String?
    var sourceBundleID: String?
    var startedAt: String
    var sceneTemplate: String?
    var extraPrompt: String?
    var includesMicrophoneAudio: Bool?

    static func capture(
        sourceTitle: String,
        sourceAppName: String?,
        sourceBundleID: String?,
        sceneTemplate: String? = nil,
        extraPrompt: String? = nil,
        includesMicrophoneAudio: Bool? = nil
    ) -> RecordingSessionMetadata {
        RecordingSessionMetadata(
            summaryTitle: nil,
            sourceTitle: sourceTitle,
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            startedAt: ISO8601DateFormatter().string(from: Date()),
            sceneTemplate: sceneTemplate,
            extraPrompt: extraPrompt,
            includesMicrophoneAudio: includesMicrophoneAudio
        )
    }

    var cloudRecordingTitle: String {
        if let summaryTitle = clean(summaryTitle) {
            return summaryTitle
        }

        if let sourceTitle = clean(sourceTitle), sourceTitle != "All system audio" {
            return sourceTitle
        }

        if let sourceAppName = clean(sourceAppName) {
            return "\(sourceAppName) recording"
        }

        return "Audio recording"
    }

    private func clean(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}
