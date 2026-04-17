import Foundation

struct RecordingResult: Equatable {
    let folderURL: URL
    let transcript: String?
    let duration: Int
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
