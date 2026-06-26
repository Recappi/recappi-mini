import AVFoundation
import Foundation
import RecappiCaptureCore

typealias CaptureStreamFormat = RecappiCaptureCore.CaptureStreamFormat
typealias SegmentedAudioWriter = CaptureSegmentedAudioWriter

struct AudioCaptureDiagnostics: Codable {
    struct FileInfo: Codable {
        let role: String
        let fileName: String
        let exists: Bool
        let byteCount: Int64?
        let sampleRate: Double?
        let channelCount: UInt32?
        let durationSeconds: Double?
        let error: String?

        init(role: String, url: URL) {
            self.role = role
            self.fileName = url.lastPathComponent
            self.exists = FileManager.default.fileExists(atPath: url.path)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            byteCount = attributes?[.size] as? Int64

            do {
                let file = try AVAudioFile(forReading: url)
                sampleRate = file.fileFormat.sampleRate
                channelCount = file.fileFormat.channelCount
                durationSeconds = file.fileFormat.sampleRate > 0
                    ? Double(file.length) / file.fileFormat.sampleRate
                    : nil
                error = nil
            } catch {
                sampleRate = nil
                channelCount = nil
                durationSeconds = nil
                self.error = error.localizedDescription
            }
        }
    }

    let createdAt: Date
    let sources: [FileInfo]
    let output: FileInfo?
    let captureHealth: [CaptureAudioHealth]

    static func write(
        sources: [URL],
        output: URL?,
        to sessionDir: URL,
        captureHealth: [CaptureAudioHealth] = []
    ) {
        let diagnostics = AudioCaptureDiagnostics(
            createdAt: Date(),
            sources: sources.map { FileInfo(role: role(for: $0), url: $0) },
            output: output.map { FileInfo(role: "mixed", url: $0) },
            captureHealth: captureHealth
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(diagnostics)
            try data.write(to: sessionDir.appendingPathComponent("audio-capture.json"))
        } catch {
            DiagnosticsLog.error(
                "recording",
                "audio_capture_diagnostics.write.failed dir=\(sessionDir.lastPathComponent) \(DiagnosticsLog.errorSummary(error))"
            )
        }
    }

    private static func role(for url: URL) -> String {
        switch url.deletingPathExtension().lastPathComponent {
        case "system": "system"
        case "mic": "mic"
        default: "source"
        }
    }
}
