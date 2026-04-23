import Foundation

struct RecordingResult: Equatable {
    let folderURL: URL
    let transcript: String?
    let duration: Int

    static func == (lhs: RecordingResult, rhs: RecordingResult) -> Bool {
        lhs.folderURL == rhs.folderURL &&
        lhs.transcript == rhs.transcript &&
        lhs.duration == rhs.duration
    }
}

enum RecorderState: Equatable {
    case idle
    case starting
    case recording
    case processing(ProcessingPhase)
    case done(result: RecordingResult)
    case error(message: String)

    var isRecording: Bool {
        self == .recording
    }

    var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }

    static func == (lhs: RecorderState, rhs: RecorderState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.starting, .starting),
             (.recording, .recording):
            return true
        case let (.processing(a), .processing(b)):
            return a == b
        case let (.done(a), .done(b)):
            return a == b
        case let (.error(a), .error(b)):
            return a == b
        default:
            return false
        }
    }
}
