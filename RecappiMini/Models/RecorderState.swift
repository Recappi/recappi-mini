import Foundation

struct RecordingResult: Equatable {
    let folderURL: URL
    let transcript: String?
    let duration: Int
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

    var requiresQuitConfirmation: Bool {
        self == .recording || self == .starting
    }

    var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }
}
