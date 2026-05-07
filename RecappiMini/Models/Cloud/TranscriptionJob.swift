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

struct RecordingJobsResponse: Decodable, Equatable, Sendable {
    let items: [TranscriptionJob]
}

struct TranscriptionJob: Codable, Equatable, Sendable {
    static func failedRecordingPlaceholder(recordingID: String) -> TranscriptionJob {
        TranscriptionJob(
            id: "recording-\(recordingID)-failed",
            status: .failed,
            transcriptId: nil,
            provider: "Recappi Cloud",
            model: "Recording processing",
            language: nil,
            prompt: nil,
            error: "Recording processing failed before a transcription job became available.",
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

    var isFailedRecordingPlaceholder: Bool {
        provider == "Recappi Cloud" &&
            model == "Recording processing" &&
            id.hasPrefix("recording-") &&
            id.hasSuffix("-failed")
    }
}

