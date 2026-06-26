import Foundation
import RecappiCaptureCore

enum AudioMixer {
    static func mix(sources: [URL], to destination: URL) async throws {
        do {
            try await CaptureAudioMixer.mix(sources: sources, to: destination)
        } catch let error as CaptureAudioError {
            switch error {
            case .sourceUnreadable(let fileName, _):
                DiagnosticsLog.error(
                    "recording",
                    "mix.source_unreadable file=\(fileName) \(DiagnosticsLog.errorSummary(error))"
                )
                throw RecorderError.exportFailed
            case .noCapturedAudio:
                throw RecorderError.noCapturedAudio
            case .exportFailed:
                throw RecorderError.exportFailed
            default:
                throw error
            }
        }
    }

    static func outputHeadroom(forSourceCount count: Int) -> Float {
        CaptureAudioMixer.outputHeadroom(forSourceCount: count)
    }
}
