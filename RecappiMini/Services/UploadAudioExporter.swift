import AVFoundation
import Foundation

enum UploadAudioExporter {
    static func ensureUploadAudio(for sessionDir: URL) async throws -> URL {
        let destination = RecordingStore.uploadAudioFileURL(in: sessionDir)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        let source = RecordingStore.audioFileURL(in: sessionDir)
        try await Task.detached(priority: .userInitiated) {
            try export(source: source, destination: destination)
        }.value
        return destination
    }

    private static func export(source: URL, destination: URL) throws {
        let inputFile = try AVAudioFile(forReading: source)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        guard let renderFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            throw UploadAudioExporterError.unsupportedFormat
        }

        engine.connect(player, to: engine.mainMixerNode, format: inputFile.processingFormat)
        try engine.enableManualRenderingMode(
            .offline,
            format: renderFormat,
            maximumFrameCount: 4_096
        )

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let outputFile = try AVAudioFile(forWriting: destination, settings: outputSettings)

        try engine.start()
        player.scheduleFile(inputFile, at: nil)
        player.play()

        guard let buffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: 4_096) else {
            throw UploadAudioExporterError.exportFailed
        }

        let maxFrames = AVAudioFramePosition(
            Double(inputFile.length) * renderFormat.sampleRate / inputFile.processingFormat.sampleRate
        )

        renderLoop: while engine.manualRenderingSampleTime < maxFrames {
            let remaining = maxFrames - engine.manualRenderingSampleTime
            let toRender = min(AVAudioFrameCount(remaining), buffer.frameCapacity)
            let status = try engine.renderOffline(toRender, to: buffer)

            switch status {
            case .success, .insufficientDataFromInputNode:
                if buffer.frameLength > 0 {
                    try outputFile.write(from: buffer)
                } else if status == .insufficientDataFromInputNode {
                    break renderLoop
                }
            case .cannotDoInCurrentContext, .error:
                throw UploadAudioExporterError.exportFailed
            @unknown default:
                throw UploadAudioExporterError.exportFailed
            }
        }

        player.stop()
        engine.stop()
    }
}

enum UploadAudioExporterError: LocalizedError {
    case unsupportedFormat
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Couldn't convert recording.m4a into upload.wav"
        case .exportFailed:
            return "Failed to prepare upload.wav for Recappi Cloud"
        }
    }
}
