import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit

// MARK: - System audio receiver

final class SystemAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: SegmentedAudioWriter

    /// Called on the capture queue for each buffer with a peak + spectrum
    /// snapshot. AudioRecorder hops this to the main actor + throttles to
    /// ~30 Hz for the waveform view.
    var onMeterFrame: ((AudioMeterFrame) -> Void)?
    var onLiveCaptionSampleBuffer: ((CMSampleBuffer) -> Void)?

    init(writer: SegmentedAudioWriter) {
        self.writer = writer
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid else { return }
        writer.append(sampleBuffer)
        onLiveCaptionSampleBuffer?(sampleBuffer)
        onMeterFrame?(AudioLevelExtractor.meterFrame(sampleBuffer, bucketCount: AudioSpectrumConfiguration.bucketCount))
    }

    func finishWriting() async throws -> URL? {
        try await writer.finishWriting()
    }
}

// MARK: - Microphone receiver

final class MicAudioOutput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let writer: SegmentedAudioWriter

    var onMeterFrame: ((AudioMeterFrame) -> Void)?

    init(writer: SegmentedAudioWriter) {
        self.writer = writer
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid else { return }
        writer.append(sampleBuffer)
        onMeterFrame?(AudioLevelExtractor.meterFrame(sampleBuffer, bucketCount: AudioSpectrumConfiguration.bucketCount))
    }

    func finishWriting() async throws -> URL? {
        try await writer.finishWriting()
    }
}
