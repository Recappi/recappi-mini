import AVFoundation
import CoreMedia
import os
import RecappiCaptureCore
@preconcurrency import ScreenCaptureKit

typealias CaptureAudioHealth = RecappiCaptureCore.CaptureAudioHealth

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

private struct CapturePeakStats {
    var meterFrameCount = 0
    var peakTotal: Float = 0
    var maxPeak: Float = 0

    mutating func record(_ frame: AudioMeterFrame) {
        meterFrameCount += 1
        peakTotal += frame.peak
        maxPeak = Swift.max(maxPeak, frame.peak)
    }

    var averagePeak: Float? {
        guard meterFrameCount > 0 else { return nil }
        return peakTotal / Float(meterFrameCount)
    }

    var maxPeakValue: Float? {
        guard meterFrameCount > 0 else { return nil }
        return maxPeak
    }
}

// MARK: - System audio receiver

final class SystemAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    /// All mutable state that the per-buffer handler shares with the metering
    /// setter and the (off-thread) health snapshot reader. Previously each of
    /// these lived behind a serial `DispatchQueue`, which charged a full
    /// queue round-trip on *every* audio buffer (~100/s) just to bump a couple
    /// of counters and read a flag. An `OSAllocatedUnfairLock` gives the same
    /// mutual exclusion and memory visibility for a tiny fraction of the cost.
    /// `meterGate` is folded in here too: it is only ever touched on the
    /// capture queue, but holding it under the same lock keeps its mutation
    /// memory-visible and removes the only piece of state that used to live
    /// outside the synchronized region.
    private struct State {
        var meterGate = AudioMeterFrameGate()
        var isMeteringEnabled = true
        var bufferCount = 0
        var firstBufferUptime: TimeInterval?
        var lastBufferUptime: TimeInterval?
        var peakStats = CapturePeakStats()
    }

    private let writer: SegmentedAudioWriter
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Called on the capture queue for each buffer with a peak + spectrum
    /// snapshot. Recording and live captions still receive every audio buffer;
    /// only the visual meter is sampled so spectrum FFT work cannot dominate
    /// the capture queues while recording.
    var onMeterFrame: ((AudioMeterFrame) -> Void)?
    var onLiveCaptionSampleBuffer: ((CMSampleBuffer) -> Void)?

    init(writer: SegmentedAudioWriter) {
        self.writer = writer
    }

    func setMeteringEnabled(_ enabled: Bool) {
        state.withLock { $0.isMeteringEnabled = enabled }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        handleAudioSampleBuffer(sampleBuffer)
    }

    func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // One short critical section per buffer: bump the counter, read the
        // metering flag, and advance the meter gate together so the gate stays
        // memory-consistent with the rest of the capture state.
        let decision = state.withLock { state -> (isFirst: Bool, meteringEnabled: Bool, shouldEmit: Bool) in
            state.bufferCount += 1
            let meteringEnabled = state.isMeteringEnabled
            let isFirst: Bool
            if state.firstBufferUptime == nil {
                state.firstBufferUptime = now
                isFirst = true
            } else {
                isFirst = false
            }
            state.lastBufferUptime = now
            let shouldEmit = meteringEnabled && state.meterGate.shouldEmit(at: now)
            return (isFirst, meteringEnabled, shouldEmit)
        }
        if decision.isFirst {
            DiagnosticsLog.event("recording", "system.first_buffer")
        }
        writer.append(sampleBuffer)
        onLiveCaptionSampleBuffer?(sampleBuffer)
        RecordingPerformanceProbe.shared.noteAudioBuffer(source: .system, at: now)
        guard decision.meteringEnabled else {
            RecordingPerformanceProbe.shared.noteMeterSkipped(source: .system, at: now)
            return
        }
        if decision.shouldEmit {
            let frame = RecordingPerformanceProbe.shared.measureMeterExtraction(source: .system) {
                AudioLevelExtractor.meterFrame(sampleBuffer, bucketCount: AudioSpectrumConfiguration.bucketCount)
            }
            state.withLock { $0.peakStats.record(frame) }
            onMeterFrame?(frame)
        } else {
            RecordingPerformanceProbe.shared.noteMeterSkipped(source: .system, at: now)
        }
    }

    func finishWriting() async throws -> URL? {
        try await writer.finishWriting()
    }

    func healthSnapshot(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CaptureAudioHealth {
        state.withLock { state in
            CaptureAudioHealth(
                source: "system",
                bufferCount: state.bufferCount,
                includedBufferCount: nil,
                firstBufferUptime: state.firstBufferUptime,
                lastBufferUptime: state.lastBufferUptime,
                secondsSinceLastBuffer: state.lastBufferUptime.map { max(now - $0, 0) },
                meterFrameCount: state.peakStats.meterFrameCount,
                averagePeak: state.peakStats.averagePeak,
                maxPeak: state.peakStats.maxPeakValue
            )
        }
    }
}

// MARK: - Microphone receiver

final class MicAudioOutput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Mirror of `SystemAudioOutput.State`: all per-buffer counters, flags and
    /// the meter gate that used to round-trip a serial `DispatchQueue` on every
    /// microphone buffer. Replaced by a single `OSAllocatedUnfairLock` to keep
    /// the same single-writer + memory-visibility guarantees at a fraction of
    /// the per-buffer cost. `meterGate` is included so it is mutated under the
    /// lock rather than (as before) outside any synchronization.
    private struct State {
        var meterGate = AudioMeterFrameGate()
        var isMeteringEnabled = true
        var includesAudio = true
        var didLogFirstBuffer = false
        var didLogFirstIncludedBuffer = false
        var bufferCount = 0
        var includedBufferCount = 0
        var firstBufferUptime: TimeInterval?
        var lastBufferUptime: TimeInterval?
        var peakStats = CapturePeakStats()
    }

    private let writer: SegmentedAudioWriter
    private let state = OSAllocatedUnfairLock(initialState: State())

    var onMeterFrame: ((AudioMeterFrame) -> Void)?

    init(writer: SegmentedAudioWriter) {
        self.writer = writer
    }

    func setIncludesAudio(_ included: Bool) {
        state.withLock { $0.includesAudio = included }
    }

    func setMeteringEnabled(_ enabled: Bool) {
        state.withLock { $0.isMeteringEnabled = enabled }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let decision = state.withLock {
            state -> (
                included: Bool,
                shouldLogFirstBuffer: Bool,
                shouldLogFirstIncludedBuffer: Bool,
                meteringEnabled: Bool,
                shouldEmit: Bool
            ) in
            let included = state.includesAudio
            state.bufferCount += 1
            if state.firstBufferUptime == nil {
                state.firstBufferUptime = now
            }
            state.lastBufferUptime = now

            var shouldLogFirstBuffer = false
            if !state.didLogFirstBuffer {
                state.didLogFirstBuffer = true
                shouldLogFirstBuffer = true
            }

            var shouldLogFirstIncludedBuffer = false
            if included {
                state.includedBufferCount += 1
                if !state.didLogFirstIncludedBuffer {
                    state.didLogFirstIncludedBuffer = true
                    shouldLogFirstIncludedBuffer = true
                }
            }

            let meteringEnabled = state.isMeteringEnabled
            // The meter gate is only advanced when we would actually emit a
            // frame (metering enabled AND this buffer is included), matching
            // the original ordering where `shouldEmit(at:)` lived behind the
            // `guard isMeteringEnabled` and the `included` check.
            let shouldEmit = meteringEnabled && included && state.meterGate.shouldEmit(at: now)
            return (included, shouldLogFirstBuffer, shouldLogFirstIncludedBuffer, meteringEnabled, shouldEmit)
        }
        let included = decision.included
        if decision.shouldLogFirstBuffer {
            DiagnosticsLog.event("recording", "mic.first_buffer included=\(included)")
        }
        if decision.shouldLogFirstIncludedBuffer {
            DiagnosticsLog.event("recording", "mic.first_included_buffer")
        }
        writer.append(sampleBuffer, muted: !included)
        RecordingPerformanceProbe.shared.noteAudioBuffer(source: .mic, at: now)
        guard decision.meteringEnabled else {
            RecordingPerformanceProbe.shared.noteMeterSkipped(source: .mic, at: now)
            return
        }
        if decision.shouldEmit {
            let frame = RecordingPerformanceProbe.shared.measureMeterExtraction(source: .mic) {
                AudioLevelExtractor.meterFrame(sampleBuffer, bucketCount: AudioSpectrumConfiguration.bucketCount)
            }
            state.withLock { $0.peakStats.record(frame) }
            onMeterFrame?(frame)
        } else {
            RecordingPerformanceProbe.shared.noteMeterSkipped(source: .mic, at: now)
        }
    }

    func finishWriting() async throws -> URL? {
        try await writer.finishWriting()
    }

    func healthSnapshot(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CaptureAudioHealth {
        state.withLock { state in
            CaptureAudioHealth(
                source: "mic",
                bufferCount: state.bufferCount,
                includedBufferCount: state.includedBufferCount,
                firstBufferUptime: state.firstBufferUptime,
                lastBufferUptime: state.lastBufferUptime,
                secondsSinceLastBuffer: state.lastBufferUptime.map { max(now - $0, 0) },
                meterFrameCount: state.peakStats.meterFrameCount,
                averagePeak: state.peakStats.averagePeak,
                maxPeak: state.peakStats.maxPeakValue
            )
        }
    }
}
