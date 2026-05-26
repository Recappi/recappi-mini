import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

/// A single utterance / sentence-sized chunk of caption content. The
/// transcriber emits segments keyed by a stable `id` (e.g. the OpenAI
/// Realtime `item_id`) so consumers can incrementally update one segment
/// at a time without reflowing the whole transcript, and so a future
/// translation layer can hang `translatedText` off the same segment id.
///
/// `sequence` preserves the ordering produced upstream — the timeline
/// is a list of segments sorted by sequence, which is more reliable
/// than sorting by id when the Realtime stream backfills items via
/// `previous_item_id`.
struct LiveCaptionSegment: Equatable, Sendable, Codable {
    let id: String
    let sourceText: String
    let translatedText: String?
    let isFinal: Bool
    let sequence: Int
}

struct LiveCaptionSnapshot: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case preparing
        case listening
        case unavailable
        case failed
    }

    let phase: Phase
    /// Ordered segments in the visible timeline. Empty when the
    /// transcriber has nothing to display yet (`.preparing`,
    /// `.unavailable`, `.failed` with no captured caption history, etc).
    let segments: [LiveCaptionSegment]
    /// Convenience: true when every segment in `segments` has
    /// `isFinal == true`. Lets consumers distinguish a stable transcript
    /// from one that still has streaming deltas.
    let allSegmentsFinal: Bool
    let message: String?

    /// Joined `sourceText` of all segments, separated by `\n`. Useful
    /// for accessibility labels, saved-transcript writers, and the
    /// "is the panel showing a placeholder?" check (empty == placeholder).
    var joinedSourceText: String {
        segments.map(\.sourceText).joined(separator: "\n")
    }

    static func statusOnly(phase: Phase, message: String?) -> LiveCaptionSnapshot {
        .init(phase: phase, segments: [], allSegmentsFinal: false, message: message)
    }
}

struct LiveCaptionEntry: Codable, Equatable, Sendable {
    let text: String
    let isFinal: Bool
    let startedAtMs: Int?
    let endedAtMs: Int?
}

@available(macOS 26.0, *)
final class LiveCaptionTranscriber: NSObject, @unchecked Sendable {
    private static let maxRecognitionRequestDuration: TimeInterval = 45
    private static let maxPendingAudioBuffers = 8
    private static let maxSavedEntryCount = 240

    private let inputQueue = DispatchQueue(label: "RecappiMini.LiveCaptionTranscriber.input")
    private let inputQueueKey = DispatchSpecificKey<Void>()
    private let pendingLock = NSLock()
    private let stateQueue = DispatchQueue(label: "RecappiMini.LiveCaptionTranscriber.state")
    private let onUpdate: @MainActor @Sendable (LiveCaptionSnapshot) -> Void

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var activeRequestStartedAt: Date?
    private var entries: [LiveCaptionEntry] = []
    private var latestPartialEntry: LiveCaptionEntry?
    private var lastPublishedText: String?
    private var isAcceptingInput = false
    private var pendingAudioBufferCount = 0

    init(onUpdate: @escaping @MainActor @Sendable (LiveCaptionSnapshot) -> Void) {
        self.onUpdate = onUpdate
        inputQueue.setSpecific(key: inputQueueKey, value: ())
    }

    static func requestSpeechAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let previousPolicy = NSApp.activationPolicy()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                SFSpeechRecognizer.requestAuthorization { status in
                    DispatchQueue.main.async {
                        NSApp.setActivationPolicy(previousPolicy)
                        continuation.resume(returning: status)
                    }
                }
            }
        }
    }

    func start(localeIdentifier: String) {
        Task { [weak self] in
            await self?.run(localeIdentifier: localeIdentifier)
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard reservePendingAudioBuffer() else { return }
        guard let buffer = autoreleasepool(invoking: { Self.pcmBuffer(from: sampleBuffer) }) else {
            releasePendingAudioBuffer()
            return
        }
        inputQueue.async { [weak self] in
            guard let self else { return }
            defer { self.releasePendingAudioBuffer() }
            guard self.isAcceptingInput else { return }
            if self.shouldRotateRecognitionRequestLocked(),
               let recognizer = self.recognizer {
                self.rotateRecognitionRequestLocked(recognizer: recognizer)
            }
            self.recognitionRequest?.append(buffer)
        }
    }

    func stop(saveTo sessionDir: URL?) {
        performOnInputQueue {
            self.isAcceptingInput = false
            self.recognitionTask?.cancel()
            self.recognitionTask = nil
            self.recognitionRequest?.endAudio()
            self.recognitionRequest = nil
            self.recognizer = nil
            self.activeRequestStartedAt = nil
        }

        if let sessionDir {
            saveEntries(to: sessionDir)
        }
    }

    private func run(localeIdentifier: String) async {
        await publish(.statusOnly(phase: .preparing, message: "Preparing live captions…"))

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            await publish(.statusOnly(phase: .unavailable, message: "Enable Speech Recognition to use live captions."))
            return
        }

        let locale = Locale(identifier: localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "en-US" : localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            await publish(.statusOnly(phase: .unavailable, message: "Live captions are not available for this language."))
            return
        }
        guard recognizer.isAvailable else {
            await publish(.statusOnly(phase: .unavailable, message: "Live captions are temporarily unavailable."))
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        inputQueue.sync {
            self.recognizer = recognizer
            self.recognitionRequest = request
            self.isAcceptingInput = true
            self.activeRequestStartedAt = Date()
        }

        NSLog("[Recappi] live captions recognizer started locale=%@", recognizer.locale.identifier)
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result, let snapshot = self?.consume(result) {
                self?.publishFromRecognitionCallback(snapshot)
            }

            if let error {
                let nsError = error as NSError
                if Self.isExpectedRecognitionCancellation(nsError) {
                    return
                }
                DiagnosticsLog.error(
                    "live-caption",
                    "local_speech.recognition.failed locale=\(recognizer.locale.identifier) \(DiagnosticsLog.errorSummary(error))"
                )
                self?.publishFromRecognitionCallback(.statusOnly(
                    phase: .failed,
                    message: error.localizedDescription
                ))
            }
        }

        await publish(.statusOnly(phase: .listening, message: "Listening for live captions…"))
    }

    private func consume(_ result: SFSpeechRecognitionResult) -> LiveCaptionSnapshot? {
        let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let isFinal = result.isFinal
        let startedAtMs = result.bestTranscription.segments.first.map { Int(($0.timestamp * 1000).rounded()) }
        let endedAtMs = result.bestTranscription.segments.last.map {
            Int((($0.timestamp + $0.duration) * 1000).rounded())
        }

        stateQueue.async { [weak self] in
            guard let self else { return }
            if self.lastPublishedText == text, !isFinal {
                return
            }
            self.lastPublishedText = text
            let entry = LiveCaptionEntry(
                text: text,
                isFinal: isFinal,
                startedAtMs: startedAtMs,
                endedAtMs: endedAtMs
            )
            if isFinal {
                self.latestPartialEntry = nil
                if self.entries.last?.text != entry.text {
                    self.entries.append(entry)
                    self.trimEntriesLocked()
                }
            } else {
                self.latestPartialEntry = entry
            }
        }

        // SFSpeechRecognizer hands us a single rolling transcript per
        // recognition session, not pre-sliced segments — so we surface
        // it as one segment whose id is stable for the lifetime of the
        // current speech result. The backend Realtime transcriber emits
        // many segments keyed by `item_id`; this fallback path emits a
        // single `sf-current` segment that gets replaced in place.
        let segment = LiveCaptionSegment(
            id: "sf-current",
            sourceText: text,
            translatedText: nil,
            isFinal: isFinal,
            sequence: 0
        )
        return LiveCaptionSnapshot(
            phase: .listening,
            segments: [segment],
            allSegmentsFinal: isFinal,
            message: nil
        )
    }

    private func publish(_ snapshot: LiveCaptionSnapshot) async {
        await MainActor.run {
            onUpdate(snapshot)
        }
    }

    private func publishFromRecognitionCallback(_ snapshot: LiveCaptionSnapshot) {
        let onUpdate = onUpdate
        Task { @MainActor in
            onUpdate(snapshot)
        }
    }

    private func saveEntries(to sessionDir: URL) {
        let finalEntries = currentEntriesSnapshot()
        guard !finalEntries.isEmpty,
              let data = try? JSONEncoder().encode(finalEntries) else {
            return
        }
        let url = sessionDir.appendingPathComponent("live-captions.json")
        try? data.write(to: url, options: .atomic)
    }

    /// Phase 2 — caller-driven snapshot used by `AudioRecorder` to
    /// drain entries into `RecordingCaptionStore` instead of going
    /// through this transcriber's own disk-writer.
    @available(macOS 26.0, *)
    func drainEntriesForTransition() -> [LiveCaptionEntry] {
        currentEntriesSnapshot()
    }

    private func currentEntriesSnapshot() -> [LiveCaptionEntry] {
        stateQueue.sync {
            let finals = entries.filter(\.isFinal)
            if !finals.isEmpty { return finals }
            return latestPartialEntry.map { [$0] } ?? []
        }
    }

    private func reservePendingAudioBuffer() -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }

        guard pendingAudioBufferCount < Self.maxPendingAudioBuffers else {
            return false
        }
        pendingAudioBufferCount += 1
        return true
    }

    private func releasePendingAudioBuffer() {
        pendingLock.lock()
        pendingAudioBufferCount = max(0, pendingAudioBufferCount - 1)
        pendingLock.unlock()
    }

    private func performOnInputQueue(_ block: () -> Void) {
        if DispatchQueue.getSpecific(key: inputQueueKey) != nil {
            block()
        } else {
            inputQueue.sync {
                block()
            }
        }
    }

    private func shouldRotateRecognitionRequestLocked(now: Date = Date()) -> Bool {
        guard let activeRequestStartedAt else { return false }
        return now.timeIntervalSince(activeRequestStartedAt) >= Self.maxRecognitionRequestDuration
    }

    private func rotateRecognitionRequestLocked(recognizer: SFSpeechRecognizer) {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        recognitionRequest = request
        activeRequestStartedAt = Date()

        NSLog("[Recappi] live captions recognizer rotated locale=%@", recognizer.locale.identifier)
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result, let snapshot = self?.consume(result) {
                self?.publishFromRecognitionCallback(snapshot)
            }

            if let error {
                let nsError = error as NSError
                if Self.isExpectedRecognitionCancellation(nsError) {
                    return
                }
                DiagnosticsLog.error(
                    "live-caption",
                    "local_speech.recognition.failed locale=\(recognizer.locale.identifier) \(DiagnosticsLog.errorSummary(error))"
                )
                self?.publishFromRecognitionCallback(.statusOnly(
                    phase: .failed,
                    message: error.localizedDescription
                ))
            }
        }
    }

    private static func isExpectedRecognitionCancellation(_ error: NSError) -> Bool {
        if error.domain == "kAFAssistantErrorDomain", error.code == 216 {
            return true
        }

        // Rotating or stopping an SFSpeech recognition request produces this
        // local-speech cancellation. It is expected control flow, not a
        // user-visible caption failure.
        return error.domain == "kLSRErrorDomain" && error.code == 301
    }

    private func trimEntriesLocked() {
        guard entries.count > Self.maxSavedEntryCount else { return }
        entries.removeFirst(entries.count - Self.maxSavedEntryCount)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sampleBuffer.isValid,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let asbd = asbdPointer.pointee
        let channelCount = max(Int(asbd.mChannelsPerFrame), 1)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: asbd.mSampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
              ),
              let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return nil
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr,
              let raw = dataPointer,
              let channels = pcmBuffer.floatChannelData else {
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        if isFloat, asbd.mBitsPerChannel == 32 {
            let sampleCount = min(totalLength / MemoryLayout<Float>.size, frameCount * channelCount)
            raw.withMemoryRebound(to: Float.self, capacity: sampleCount) { source in
                for frame in 0..<frameCount {
                    for channel in 0..<channelCount {
                        let index = sourceIndex(frame: frame, channel: channel, frameCount: frameCount, channelCount: channelCount, isNonInterleaved: isNonInterleaved)
                        channels[channel][frame] = index < sampleCount ? source[index] : 0
                    }
                }
            }
        } else if asbd.mBitsPerChannel == 16 {
            let sampleCount = min(totalLength / MemoryLayout<Int16>.size, frameCount * channelCount)
            raw.withMemoryRebound(to: Int16.self, capacity: sampleCount) { source in
                for frame in 0..<frameCount {
                    for channel in 0..<channelCount {
                        let index = sourceIndex(frame: frame, channel: channel, frameCount: frameCount, channelCount: channelCount, isNonInterleaved: isNonInterleaved)
                        channels[channel][frame] = index < sampleCount ? Float(source[index]) / 32768 : 0
                    }
                }
            }
        } else {
            return nil
        }

        return pcmBuffer
    }

    private static func sourceIndex(
        frame: Int,
        channel: Int,
        frameCount: Int,
        channelCount: Int,
        isNonInterleaved: Bool
    ) -> Int {
        if isNonInterleaved {
            return (channel * frameCount) + frame
        }
        return (frame * channelCount) + channel
    }
}
