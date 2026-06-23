import Foundation

public struct RecappiCloudSession: Codable, Equatable, Sendable {
    public let userId: String
    public let email: String
    public let name: String
    public let imageURL: String?
    public let expiresAt: String
    public let backendOrigin: String
}

public struct RecappiCloudAuthContext: Equatable, Sendable {
    public let origin: String
    public let bearerToken: String

    public init(origin: String, bearerToken: String) {
        self.origin = RecappiCloudOriginResolver.normalizeOrigin(origin)
        self.bearerToken = bearerToken
    }
}

public enum RecappiCloudErrorCode: String, Codable, Equatable, Sendable {
    case invalidArgument = "usage.invalid_argument"
    case notSignedIn = "auth.not_signed_in"
    case unauthorized = "auth.unauthorized"
    case inputNotFound = "input.not_found"
    case unsupportedType = "input.unsupported_type"
    case durationUnavailable = "input.duration_unavailable"
    case emptySelection = "input.empty_selection"
    case partialFailure = "input.partial_failure"
    case uploadInProgress = "cloud.conflict.upload_in_progress"
    case recordingNotReady = "cloud.recording_not_ready"
    case jobFailed = "cloud.job_failed"
    case jobTimedOut = "cloud.job_timed_out"
    case invalidResponse = "cloud.invalid_response"
    case httpError = "cloud.http_error"
    case unexpected = "internal.unexpected"
}

public struct RecappiCloudErrorDescriptor: Codable, Equatable, Sendable {
    public let code: RecappiCloudErrorCode
    public let exitCode: Int32
    public let retryable: Bool
    public let message: String
    public let hint: String?

    public init(
        code: RecappiCloudErrorCode,
        exitCode: Int32,
        retryable: Bool,
        message: String,
        hint: String? = nil
    ) {
        self.code = code
        self.exitCode = exitCode
        self.retryable = retryable
        self.message = message
        self.hint = hint
    }

    public static func invalidArgument(_ message: String) -> Self {
        Self(code: .invalidArgument, exitCode: 2, retryable: false, message: message)
    }

    public static func partialFailure(failedCount: Int, totalCount: Int, exitCode: Int32) -> Self {
        Self(
            code: .partialFailure,
            exitCode: exitCode,
            retryable: false,
            message: "\(failedCount) of \(totalCount) files failed to upload.",
            hint: "Inspect data.failures for per-file error codes and retry only the failed files."
        )
    }

    public static func unexpected(_ message: String) -> Self {
        Self(
            code: .unexpected,
            exitCode: 1,
            retryable: false,
            message: message,
            hint: "Retry once if this looks transient; otherwise report the command, arguments, and error text."
        )
    }

    public static func describe(_ error: Error) -> Self {
        if let cloudError = error as? RecappiCloudError {
            return cloudError.descriptor
        }
        return .unexpected(error.localizedDescription)
    }
}

public enum RecappiCloudError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case notSignedIn
    case unauthorized
    case http(statusCode: Int, message: String)
    case fileMissing(String)
    case unsupportedFileType(String)
    case durationUnavailable(String)
    case directoryHasNoSupportedFiles(String)
    case recordingNotReady(String)
    case jobFailed(String)
    case jobTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Recappi backend URL."
        case .invalidResponse:
            return "Invalid response from Recappi Cloud."
        case .notSignedIn:
            return "No Recappi Cloud login was found. Open Recappi Mini and sign in first."
        case .unauthorized:
            return "Recappi Cloud session expired. Sign in again in Recappi Mini."
        case .http(let statusCode, let message):
            return "Recappi API error (status \(statusCode)): \(message)"
        case .fileMissing(let path):
            return "File not found: \(path)"
        case .unsupportedFileType(let path):
            return "Unsupported audio file type: \(path)"
        case .durationUnavailable(let path):
            return "Audio duration is unavailable for \(path). Recappi Cloud requires duration for non-WAV uploads."
        case .directoryHasNoSupportedFiles(let path):
            return "No supported audio files found in \(path)."
        case .recordingNotReady(let recordingId):
            return "Recording is not ready for transcription: \(recordingId)"
        case .jobFailed(let message):
            return message
        case .jobTimedOut(let jobId):
            return "Timed out waiting for transcription job \(jobId)."
        }
    }

    public var descriptor: RecappiCloudErrorDescriptor {
        switch self {
        case .invalidURL:
            return .invalidArgument("Invalid Recappi backend URL.")
        case .invalidResponse:
            return RecappiCloudErrorDescriptor(
                code: .invalidResponse,
                exitCode: 5,
                retryable: true,
                message: "Recappi Cloud returned an invalid response.",
                hint: "Retry the command. If it keeps failing, capture the command output and report it."
            )
        case .notSignedIn:
            return RecappiCloudErrorDescriptor(
                code: .notSignedIn,
                exitCode: 3,
                retryable: false,
                message: "Not logged in.",
                hint: "Open Recappi Mini, sign in, then run this command again."
            )
        case .unauthorized:
            return RecappiCloudErrorDescriptor(
                code: .unauthorized,
                exitCode: 3,
                retryable: false,
                message: "Recappi Cloud rejected the current login.",
                hint: "Open Recappi Mini, sign in again, then run this command again."
            )
        case .http(let statusCode, let message):
            switch statusCode {
            case 401, 403:
                return RecappiCloudErrorDescriptor(
                    code: .unauthorized,
                    exitCode: 3,
                    retryable: false,
                    message: "Recappi Cloud rejected the current login.",
                    hint: "Open Recappi Mini, sign in again, then run this command again."
                )
            case 409:
                return RecappiCloudErrorDescriptor(
                    code: .uploadInProgress,
                    exitCode: 5,
                    retryable: true,
                    message: "Another upload is already in progress for this account.",
                    hint: "Wait for the current upload to finish, then retry this command."
                )
            default:
                return RecappiCloudErrorDescriptor(
                    code: .httpError,
                    exitCode: 5,
                    retryable: statusCode == 429 || (500...599).contains(statusCode),
                    message: "Recappi API error (status \(statusCode)): \(message)",
                    hint: statusCode == 429 || (500...599).contains(statusCode) ? "Retry after a short delay." : nil
                )
            }
        case .fileMissing(let path):
            return RecappiCloudErrorDescriptor(
                code: .inputNotFound,
                exitCode: 4,
                retryable: false,
                message: "File not found: \(path)"
            )
        case .unsupportedFileType(let path):
            return RecappiCloudErrorDescriptor(
                code: .unsupportedType,
                exitCode: 4,
                retryable: false,
                message: "Unsupported audio file type: \(path)",
                hint: "Use WAV, MP3, AAC, M4A, OGG, FLAC, AIFF, or AIF."
            )
        case .durationUnavailable(let path):
            return RecappiCloudErrorDescriptor(
                code: .durationUnavailable,
                exitCode: 4,
                retryable: false,
                message: "Audio duration is unavailable for \(path).",
                hint: "Convert the file to WAV or a supported audio container with readable duration metadata."
            )
        case .directoryHasNoSupportedFiles(let path):
            return RecappiCloudErrorDescriptor(
                code: .emptySelection,
                exitCode: 4,
                retryable: false,
                message: "No supported audio files found in \(path).",
                hint: "Pass a supported audio file or a directory containing supported audio files."
            )
        case .recordingNotReady(let recordingId):
            return RecappiCloudErrorDescriptor(
                code: .recordingNotReady,
                exitCode: 5,
                retryable: true,
                message: "Recording is not ready for transcription: \(recordingId)",
                hint: "Wait briefly, then retry the transcription or jobs wait command."
            )
        case .jobFailed(let message):
            return RecappiCloudErrorDescriptor(
                code: .jobFailed,
                exitCode: 5,
                retryable: false,
                message: message
            )
        case .jobTimedOut(let jobId):
            return RecappiCloudErrorDescriptor(
                code: .jobTimedOut,
                exitCode: 5,
                retryable: true,
                message: "Timed out waiting for transcription job \(jobId).",
                hint: "Run recappi jobs wait \(jobId) again to resume polling."
            )
        }
    }
}

public enum RecappiCloudJobStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed

    public var isActive: Bool {
        self == .queued || self == .running
    }
}

public struct RecappiCloudChunkProgress: Codable, Equatable, Sendable {
    public struct FailedRange: Codable, Equatable, Sendable {
        public let startMs: Int
        public let endMs: Int
        public let retryable: Bool?
        public let message: String
    }

    public let completedDurationMs: Int
    public let totalDurationMs: Int
    public let percent: Double
    public let failedRanges: [FailedRange]

    enum CodingKeys: String, CodingKey {
        case completedDurationMs
        case totalDurationMs
        case percent
        case failedRanges = "failedChunks"
    }

    public init(
        completedDurationMs: Int,
        totalDurationMs: Int,
        percent: Double,
        failedRanges: [FailedRange]
    ) {
        self.completedDurationMs = completedDurationMs
        self.totalDurationMs = totalDurationMs
        self.percent = percent
        self.failedRanges = failedRanges
    }
}

public struct RecappiCloudJob: Codable, Equatable, Sendable {
    public let id: String
    public let status: RecappiCloudJobStatus
    public let transcriptId: String?
    public let provider: String
    public let model: String
    public let language: String?
    public let prompt: String?
    public let error: String?
    public let attempts: Int?
    public let enqueuedAt: Int?
    public let startedAt: Int?
    public let finishedAt: Int?
    public let chunkProgress: RecappiCloudChunkProgress?
}

public struct RecappiCloudUploadResult: Codable, Equatable, Sendable {
    public let filePath: String
    public let recordingId: String
    public let jobId: String?
    public let transcriptId: String?
    public let status: String

    public init(
        filePath: String,
        recordingId: String,
        jobId: String?,
        transcriptId: String?,
        status: String
    ) {
        self.filePath = filePath
        self.recordingId = recordingId
        self.jobId = jobId
        self.transcriptId = transcriptId
        self.status = status
    }
}

public struct RecappiCloudUploadFailure: Codable, Equatable, Sendable {
    public let filePath: String
    public let error: RecappiCloudErrorDescriptor

    public init(filePath: String, error: RecappiCloudErrorDescriptor) {
        self.filePath = filePath
        self.error = error
    }
}

public struct RecappiCloudUploadBatchResult: Codable, Equatable, Sendable {
    public let successes: [RecappiCloudUploadResult]
    public let failures: [RecappiCloudUploadFailure]
    public let totalCount: Int

    public init(
        successes: [RecappiCloudUploadResult],
        failures: [RecappiCloudUploadFailure],
        totalCount: Int? = nil
    ) {
        self.successes = successes
        self.failures = failures
        self.totalCount = totalCount ?? successes.count + failures.count
    }

    public var isCompleteSuccess: Bool {
        failures.isEmpty
    }

    public var attemptedCount: Int {
        successes.count + failures.count
    }

    public var exitCode: Int32 {
        failures.map(\.error.exitCode).max() ?? 0
    }

    public var partialFailureDescriptor: RecappiCloudErrorDescriptor? {
        guard !failures.isEmpty else { return nil }
        return .partialFailure(failedCount: failures.count, totalCount: totalCount, exitCode: exitCode)
    }
}

public enum RecappiCloudOperationEventType: String, Codable, Equatable, Sendable {
    case started
    case progress
    case retry
    case result
    case error
}

public struct RecappiCloudOperationEvent: Codable, Equatable, Sendable {
    public let type: RecappiCloudOperationEventType
    public let command: String
    public let filePath: String?
    public let recordingId: String?
    public let jobId: String?
    public let status: String?
    public let percent: Double?
    public let message: String?
    public let error: RecappiCloudErrorDescriptor?

    public init(
        type: RecappiCloudOperationEventType,
        command: String,
        filePath: String? = nil,
        recordingId: String? = nil,
        jobId: String? = nil,
        status: String? = nil,
        percent: Double? = nil,
        message: String? = nil,
        error: RecappiCloudErrorDescriptor? = nil
    ) {
        self.type = type
        self.command = command
        self.filePath = filePath
        self.recordingId = recordingId
        self.jobId = jobId
        self.status = status
        self.percent = percent
        self.message = message
        self.error = error
    }

    public static func started(command: String, filePath: String? = nil, message: String? = nil) -> Self {
        Self(type: .started, command: command, filePath: filePath, message: message)
    }

    public static func progress(
        command: String,
        filePath: String? = nil,
        recordingId: String? = nil,
        jobId: String? = nil,
        status: String? = nil,
        percent: Double? = nil,
        message: String? = nil
    ) -> Self {
        Self(
            type: .progress,
            command: command,
            filePath: filePath,
            recordingId: recordingId,
            jobId: jobId,
            status: status,
            percent: percent,
            message: message
        )
    }

    public static func result(
        command: String,
        filePath: String? = nil,
        recordingId: String? = nil,
        jobId: String? = nil,
        status: String? = nil,
        percent: Double? = nil,
        message: String? = nil
    ) -> Self {
        Self(
            type: .result,
            command: command,
            filePath: filePath,
            recordingId: recordingId,
            jobId: jobId,
            status: status,
            percent: percent,
            message: message
        )
    }

    public static func error(
        command: String,
        descriptor: RecappiCloudErrorDescriptor,
        filePath: String? = nil
    ) -> Self {
        Self(
            type: .error,
            command: command,
            filePath: filePath,
            message: descriptor.message,
            error: descriptor
        )
    }
}

public enum RecappiCloudUploadEvent: Equatable, Sendable {
    case creatingRecording(filePath: String)
    case uploading(filePath: String, progress: Double)
    case completingUpload(filePath: String)
    case startingTranscription(recordingId: String)
    case transcriptionProgress(jobId: String, status: RecappiCloudJobStatus, percent: Double?)
    case finished(RecappiCloudUploadResult)

    public func operationEvent(command: String = "upload") -> RecappiCloudOperationEvent {
        switch self {
        case .creatingRecording(let filePath):
            return .started(command: command, filePath: filePath, message: "Preparing recording")
        case .uploading(let filePath, let progress):
            return .progress(
                command: command,
                filePath: filePath,
                status: "uploading",
                percent: max(0, min(100, progress * 100))
            )
        case .completingUpload(let filePath):
            return .progress(command: command, filePath: filePath, status: "finishing_upload")
        case .startingTranscription(let recordingId):
            return .progress(
                command: command,
                recordingId: recordingId,
                status: "starting_transcription"
            )
        case .transcriptionProgress(let jobId, let status, let percent):
            return .progress(
                command: command,
                jobId: jobId,
                status: status.rawValue,
                percent: percent.map { max(0, min(100, $0)) }
            )
        case .finished(let result):
            return .result(
                command: command,
                filePath: result.filePath,
                recordingId: result.recordingId,
                jobId: result.jobId,
                status: result.status,
                percent: 100,
                message: "Upload complete"
            )
        }
    }
}

public struct RecappiCloudUploadOptions: Equatable, Sendable {
    public var title: String?
    public var transcribe: Bool
    public var waitForTranscription: Bool
    public var language: String
    public var force: Bool
    public var provider: String?
    public var prompt: String?

    public init(
        title: String? = nil,
        transcribe: Bool = false,
        waitForTranscription: Bool = false,
        language: String = "en",
        force: Bool = false,
        provider: String? = nil,
        prompt: String? = nil
    ) {
        self.title = title
        self.transcribe = transcribe
        self.waitForTranscription = waitForTranscription
        self.language = language
        self.force = force
        self.provider = provider
        self.prompt = prompt
    }
}
