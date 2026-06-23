import Foundation

struct StartTranscriptionRequest: Encodable {
    let provider: String?
    let language: String
    let force: Bool
    let prompt: String?

    init(
        provider: String?,
        language: String,
        force: Bool,
        prompt: String?
    ) {
        self.provider = provider
        self.language = language
        self.force = force
        self.prompt = prompt
    }
}

enum RemoteJobStatus: String, Codable, Equatable {
    case queued
    case running
    case succeeded
    case failed

    var isActive: Bool {
        self == .queued || self == .running
    }

    var displayName: String {
        switch self {
        case .queued:
            return "Queued"
        case .running:
            return "Running"
        case .succeeded:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }
}

struct StartTranscriptionResponse: Decodable {
    let jobId: String
    let status: RemoteJobStatus
    let transcriptId: String?
}

/// Response of `POST /api/jobs/:id/retry-failed-chunks`. The server re-plans
/// the failed chunks and flips the job back to `queued`, returning the fresh
/// status + progress (not a full job row).
struct RetryFailedChunksResponse: Decodable, Sendable {
    let jobId: String
    let status: RemoteJobStatus
    let chunkProgress: TranscriptionJobChunkProgress?
}

struct RecordingJobsResponse: Decodable, Equatable, Sendable {
    let items: [TranscriptionJob]
}

/// Per-part progress for a long recording transcribed with smart chunking.
/// Mirrors the server contract (`PublicTranscriptionJobChunkProgress`). Only
/// present on jobs that were chunked; absent on whole-file jobs.
struct TranscriptionJobChunkProgress: Codable, Equatable, Sendable {
    /// Lifecycle of a single chunk. Decodes unknown future values as
    /// `.pending` so a new server status never breaks the whole job decode
    /// (and with it the job history list).
    enum ChunkStatus: String, Codable, Equatable, Sendable {
        case pending
        case running
        case completed
        case failed

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = ChunkStatus(rawValue: raw) ?? .pending
        }
    }

    struct Chunk: Codable, Equatable, Sendable {
        let index: Int
        let status: ChunkStatus
        let startMs: Int
        let endMs: Int
        let durationMs: Int
        let attempts: Int
        let retryable: Bool?
        let message: String?
    }

    struct FailedChunk: Codable, Equatable, Sendable, Identifiable {
        let index: Int
        let startMs: Int
        let endMs: Int
        let retryable: Bool?
        let message: String

        var id: Int { index }
    }

    let total: Int
    let pending: Int
    let running: Int
    let completed: Int
    let failed: Int
    let currentIndex: Int?
    let completedDurationMs: Int
    let totalDurationMs: Int
    /// Duration-weighted completion, 0–100.
    let percent: Double
    let chunks: [Chunk]
    let failedChunks: [FailedChunk]

    /// True when at least one failed chunk can still be retried.
    var hasRetryableFailures: Bool {
        failedChunks.contains { $0.retryable == true }
    }
}

struct TranscriptionJob: Codable, Equatable, Sendable {
    static func failedRecordingPlaceholder(
        recordingID: String,
        error: String = "Recording processing failed before a transcription job became available."
    ) -> TranscriptionJob {
        TranscriptionJob(
            id: "recording-\(recordingID)-failed",
            status: .failed,
            transcriptId: nil,
            provider: "Recappi Cloud",
            model: "Recording processing",
            language: nil,
            prompt: nil,
            error: error,
            attempts: nil,
            enqueuedAt: nil,
            startedAt: nil,
            finishedAt: nil
        )
    }

    let id: String
    let status: RemoteJobStatus
    let transcriptId: String?
    let provider: String
    let model: String
    let language: String?
    let prompt: String?
    let error: String?
    let attempts: Int?
    let enqueuedAt: Int?
    let startedAt: Int?
    let finishedAt: Int?
    /// Smart-chunk progress; nil for whole-file jobs. A `var` with a default
    /// so it still decodes (a `let` with a default is silently skipped by
    /// synthesized Codable) while keeping the memberwise initializer's default
    /// intact for the `failedRecordingPlaceholder` factory and other sites.
    var chunkProgress: TranscriptionJobChunkProgress? = nil

    var isFailedRecordingPlaceholder: Bool {
        provider == "Recappi Cloud" &&
            model == "Recording processing" &&
            id.hasPrefix("recording-") &&
            id.hasSuffix("-failed")
    }
}
