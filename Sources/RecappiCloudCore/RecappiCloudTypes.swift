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

public enum RecappiCloudUploadEvent: Equatable, Sendable {
    case creatingRecording(filePath: String)
    case uploading(filePath: String, progress: Double)
    case completingUpload(filePath: String)
    case startingTranscription(recordingId: String)
    case transcriptionProgress(jobId: String, status: RecappiCloudJobStatus, percent: Double?)
    case finished(RecappiCloudUploadResult)
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
