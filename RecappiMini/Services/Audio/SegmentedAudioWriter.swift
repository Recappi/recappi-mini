import Foundation
import RecappiCaptureCore

typealias CaptureStreamFormat = RecappiCaptureCore.CaptureStreamFormat
typealias SegmentedAudioWriter = CaptureSegmentedAudioWriter

struct AudioCaptureDiagnostics: Codable {
    let createdAt: Date
    let sources: [CaptureAudioDiagnostics.FileInfo]
    let output: CaptureAudioDiagnostics.FileInfo?
    let captureHealth: [CaptureAudioHealth]

    static func write(
        sources: [URL],
        output: URL?,
        to sessionDir: URL,
        captureHealth: [CaptureAudioHealth] = []
    ) {
        do {
            try RecappiCaptureCore.CaptureAudioDiagnostics.write(
                sources: sources,
                output: output,
                to: sessionDir,
                captureHealth: captureHealth
            )
        } catch {
            DiagnosticsLog.error(
                "recording",
                "audio_capture_diagnostics.write.failed dir=\(sessionDir.lastPathComponent) \(DiagnosticsLog.errorSummary(error))"
            )
        }
    }
}
