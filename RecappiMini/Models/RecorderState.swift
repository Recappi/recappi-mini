import Foundation

struct RecordingResult: Equatable {
    let folderURL: URL
    let transcript: String?
    let duration: Int
    /// Populated when an LLM provider successfully ran; nil when the user
    /// chose the transcript-only path (provider = .none) or the run errored
    /// before summarization. Drives the done-state preview + action bullets.
    let insights: MeetingInsights?

    static func == (lhs: RecordingResult, rhs: RecordingResult) -> Bool {
        lhs.folderURL == rhs.folderURL &&
        lhs.transcript == rhs.transcript &&
        lhs.duration == rhs.duration &&
        lhs.insightsSummary == rhs.insightsSummary &&
        lhs.insightsDecisionCount == rhs.insightsDecisionCount &&
        lhs.insightsActionCount == rhs.insightsActionCount
    }

    // MeetingInsights is not Equatable (arrays of non-Equatable structs), so
    // compare only the coarse dimensions that affect UI re-render.
    private var insightsSummary: String { insights?.summary ?? "" }
    private var insightsDecisionCount: Int { insights?.keyDecisions.count ?? 0 }
    private var insightsActionCount: Int { insights?.actionItems.count ?? 0 }
}

enum RecorderState: Equatable {
    case idle
    case recording
    case stopping
    case transcribing
    case summarizing
    case done(result: RecordingResult)
    case error(message: String)

    var isRecording: Bool {
        self == .recording
    }

    var isProcessing: Bool {
        switch self {
        case .stopping, .transcribing, .summarizing:
            return true
        default:
            return false
        }
    }

    static func == (lhs: RecorderState, rhs: RecorderState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.recording, .recording),
             (.stopping, .stopping),
             (.transcribing, .transcribing),
             (.summarizing, .summarizing):
            return true
        case let (.done(a), .done(b)):
            return a == b
        case let (.error(a), .error(b)):
            return a == b
        default:
            return false
        }
    }
}
