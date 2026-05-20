import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit

final class RecordingPerformanceProbe: @unchecked Sendable {
    enum AudioSource {
        case system
        case mic
    }

    static let shared = RecordingPerformanceProbe()

    private struct SourceStats {
        var buffers = 0
        var emittedMeters = 0
        var skippedMeters = 0
        var extractionCount = 0
        var extractionTotalMs = 0.0
        var extractionMaxMs = 0.0
    }

    private let isEnabled = UITestModeConfiguration.shared.perfLogEnabled
    private let reportInterval: TimeInterval = 2.0
    private let lock = NSLock()
    private var lastReportAt = ProcessInfo.processInfo.systemUptime
    private var systemStats = SourceStats()
    private var micStats = SourceStats()
    private var meterTasksScheduled = 0
    private var meterFramesOnMain = 0
    private var levelPublishes = 0
    private var historyPublishes = 0
    private var waveformUpdates = 0
    private var waveformReleaseUpdates = 0

    func noteAudioBuffer(source: AudioSource, at now: TimeInterval) {
        mutate(at: now) {
            update(source: source) { stats in
                stats.buffers += 1
            }
        }
    }

    func noteMeterSkipped(source: AudioSource, at now: TimeInterval) {
        mutate(at: now) {
            update(source: source) { stats in
                stats.skippedMeters += 1
            }
        }
    }

    func measureMeterExtraction(
        source: AudioSource,
        _ work: () -> AudioMeterFrame
    ) -> AudioMeterFrame {
        guard isEnabled else { return work() }
        let begin = CFAbsoluteTimeGetCurrent()
        let frame = work()
        let ms = (CFAbsoluteTimeGetCurrent() - begin) * 1000.0
        mutate(at: ProcessInfo.processInfo.systemUptime) {
            update(source: source) { stats in
                stats.emittedMeters += 1
                stats.extractionCount += 1
                stats.extractionTotalMs += ms
                stats.extractionMaxMs = max(stats.extractionMaxMs, ms)
            }
        }
        return frame
    }

    func noteMeterTaskScheduled() {
        mutate(at: ProcessInfo.processInfo.systemUptime) {
            meterTasksScheduled += 1
        }
    }

    func noteMeterFrameOnMain() {
        mutate(at: ProcessInfo.processInfo.systemUptime) {
            meterFramesOnMain += 1
        }
    }

    func noteLevelPublish() {
        mutate(at: ProcessInfo.processInfo.systemUptime) {
            levelPublishes += 1
        }
    }

    func noteHistoryPublish() {
        mutate(at: ProcessInfo.processInfo.systemUptime) {
            historyPublishes += 1
        }
    }

    func noteWaveformUpdate(releasing: Bool) {
        mutate(at: ProcessInfo.processInfo.systemUptime) {
            waveformUpdates += 1
            if releasing {
                waveformReleaseUpdates += 1
            }
        }
    }

    private func mutate(at now: TimeInterval, _ update: () -> Void) {
        guard isEnabled else { return }

        let summary: String?
        lock.lock()
        update()
        if now - lastReportAt >= reportInterval {
            summary = makeSummary(interval: now - lastReportAt)
            resetCounters()
            lastReportAt = now
        } else {
            summary = nil
        }
        lock.unlock()

        if let summary {
            PerfLog.event("recording.profile", extra: summary)
        }
    }

    private func update(source: AudioSource, _ update: (inout SourceStats) -> Void) {
        switch source {
        case .system:
            update(&systemStats)
        case .mic:
            update(&micStats)
        }
    }

    private func makeSummary(interval: TimeInterval) -> String {
        let systemAverage = averageMs(systemStats)
        let micAverage = averageMs(micStats)
        return String(
            format: "interval=%.1fs systemBuffers=%d systemMeters=%d systemSkipped=%d systemExtractAvgMs=%.2f systemExtractMaxMs=%.2f micBuffers=%d micMeters=%d micSkipped=%d micExtractAvgMs=%.2f micExtractMaxMs=%.2f meterTasks=%d meterMain=%d levelPublishes=%d historyPublishes=%d waveformUpdates=%d waveformReleases=%d",
            interval,
            systemStats.buffers,
            systemStats.emittedMeters,
            systemStats.skippedMeters,
            systemAverage,
            systemStats.extractionMaxMs,
            micStats.buffers,
            micStats.emittedMeters,
            micStats.skippedMeters,
            micAverage,
            micStats.extractionMaxMs,
            meterTasksScheduled,
            meterFramesOnMain,
            levelPublishes,
            historyPublishes,
            waveformUpdates,
            waveformReleaseUpdates
        )
    }

    private func averageMs(_ stats: SourceStats) -> Double {
        guard stats.extractionCount > 0 else { return 0 }
        return stats.extractionTotalMs / Double(stats.extractionCount)
    }

    private func resetCounters() {
        systemStats = SourceStats()
        micStats = SourceStats()
        meterTasksScheduled = 0
        meterFramesOnMain = 0
        levelPublishes = 0
        historyPublishes = 0
        waveformUpdates = 0
        waveformReleaseUpdates = 0
    }
}

struct AudioMeterFrameGate {
    static let defaultInterval: TimeInterval = 1.0 / 12.0

    var minimumInterval: TimeInterval = Self.defaultInterval
    private var lastEmitTime: TimeInterval?

    init(minimumInterval: TimeInterval = Self.defaultInterval) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldEmit(at now: TimeInterval) -> Bool {
        guard let lastEmitTime else {
            self.lastEmitTime = now
            return true
        }
        guard now - lastEmitTime >= minimumInterval else {
            return false
        }
        self.lastEmitTime = now
        return true
    }
}

// MARK: - System audio receiver

final class SystemAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: SegmentedAudioWriter
    private var meterGate = AudioMeterFrameGate()

    /// Called on the capture queue for each buffer with a peak + spectrum
    /// snapshot. Recording and live captions still receive every audio buffer;
    /// only the visual meter is sampled so spectrum FFT work cannot dominate
    /// the capture queues while recording.
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
        let now = ProcessInfo.processInfo.systemUptime
        RecordingPerformanceProbe.shared.noteAudioBuffer(source: .system, at: now)
        if meterGate.shouldEmit(at: now) {
            let frame = RecordingPerformanceProbe.shared.measureMeterExtraction(source: .system) {
                AudioLevelExtractor.meterFrame(sampleBuffer, bucketCount: AudioSpectrumConfiguration.bucketCount)
            }
            onMeterFrame?(frame)
        } else {
            RecordingPerformanceProbe.shared.noteMeterSkipped(source: .system, at: now)
        }
    }

    func finishWriting() async throws -> URL? {
        try await writer.finishWriting()
    }
}

// MARK: - Microphone receiver

final class MicAudioOutput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let writer: SegmentedAudioWriter
    private let stateQueue = DispatchQueue(label: "RecappiMini.MicAudioOutput.state")
    private var meterGate = AudioMeterFrameGate()
    private var includesAudio = true
    private var didLogFirstBuffer = false
    private var didLogFirstIncludedBuffer = false

    var onMeterFrame: ((AudioMeterFrame) -> Void)?

    init(writer: SegmentedAudioWriter) {
        self.writer = writer
    }

    func setIncludesAudio(_ included: Bool) {
        stateQueue.sync {
            includesAudio = included
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid else { return }
        let included = stateQueue.sync { includesAudio }
        if !didLogFirstBuffer {
            didLogFirstBuffer = true
            DiagnosticsLog.event("recording", "mic.first_buffer included=\(included)")
        }
        if included, !didLogFirstIncludedBuffer {
            didLogFirstIncludedBuffer = true
            DiagnosticsLog.event("recording", "mic.first_included_buffer")
        }
        writer.append(sampleBuffer, muted: !included)
        let now = ProcessInfo.processInfo.systemUptime
        RecordingPerformanceProbe.shared.noteAudioBuffer(source: .mic, at: now)
        if included, meterGate.shouldEmit(at: now) {
            let frame = RecordingPerformanceProbe.shared.measureMeterExtraction(source: .mic) {
                AudioLevelExtractor.meterFrame(sampleBuffer, bucketCount: AudioSpectrumConfiguration.bucketCount)
            }
            onMeterFrame?(frame)
        } else {
            RecordingPerformanceProbe.shared.noteMeterSkipped(source: .mic, at: now)
        }
    }

    func finishWriting() async throws -> URL? {
        try await writer.finishWriting()
    }
}
