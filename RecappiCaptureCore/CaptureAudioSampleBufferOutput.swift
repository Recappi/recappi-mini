import CoreMedia
import Foundation

public typealias CaptureAudioSampleBufferTap = @Sendable (_ input: CaptureLevel.Input, _ sampleBuffer: CMSampleBuffer) -> Void

public final class CaptureAudioSampleBufferOutput: @unchecked Sendable {
    private let writer: CaptureSegmentedAudioWriter
    private let input: CaptureLevel.Input
    private let startedAtUptime: TimeInterval
    private let levelInterval: TimeInterval
    private let uptime: () -> TimeInterval
    private let onSampleBuffer: CaptureAudioSampleBufferTap?
    private let onLevel: (CaptureLevel) -> Void
    private var lastLevelEmitUptime: TimeInterval?

    public init(
        writer: CaptureSegmentedAudioWriter,
        input: CaptureLevel.Input,
        startedAtUptime: TimeInterval,
        levelInterval: TimeInterval = 1.0 / 12.0,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onSampleBuffer: CaptureAudioSampleBufferTap? = nil,
        onLevel: @escaping (CaptureLevel) -> Void
    ) {
        self.writer = writer
        self.input = input
        self.startedAtUptime = startedAtUptime
        self.levelInterval = levelInterval
        self.uptime = uptime
        self.onSampleBuffer = onSampleBuffer
        self.onLevel = onLevel
    }

    public func append(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid else { return }
        writer.append(sampleBuffer)
        onSampleBuffer?(input, sampleBuffer)
        emitLevelIfNeeded(sampleBuffer)
    }

    public func finishWriting() async throws -> URL? {
        try await writer.finishWriting()
    }

    private func emitLevelIfNeeded(_ sampleBuffer: CMSampleBuffer) {
        let now = uptime()
        if let lastLevelEmitUptime, now - lastLevelEmitUptime < levelInterval {
            return
        }
        lastLevelEmitUptime = now
        let atMs = Int64(max(0, (now - startedAtUptime) * 1_000).rounded())
        onLevel(CaptureAudioLevelExtractor.captureLevel(sampleBuffer, input: input, atMs: atMs))
    }
}
