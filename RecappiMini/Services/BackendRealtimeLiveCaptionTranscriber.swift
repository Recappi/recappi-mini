import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import Foundation

final class BackendRealtimeLiveCaptionTranscriber: NSObject, @unchecked Sendable {
    /// Two distinct upstream session shapes — different OpenAI models,
    /// different event vocabularies, different segmentation source-of-
    /// truth. We multiplex them inside one transcriber so audio capture,
    /// reconnect handling, and UI plumbing stay the same.
    enum Mode {
        /// Standard transcription session (`gpt-realtime-whisper`).
        /// Upstream emits `item_id`-keyed segments with explicit `delta`
        /// and `completed` events; our `TranscriptItem` table is the
        /// source of truth.
        case transcription
        /// Translation session (`gpt-realtime-translate`,
        /// `includeSourceTranscript=true`). Upstream is a continuous
        /// stream of source/target deltas with no item_id, completed,
        /// or commit/clear events; the client must do its own
        /// segmentation. Audio + close events use `session.*`-prefixed
        /// types; commit/clear are forbidden by the proxy.
        case translation(targetLanguage: String)

        var isTranslation: Bool {
            if case .translation = self { return true }
            return false
        }
    }

    private static let maxPendingAudioBuffers = 8
    /// Memory safety net (~10h of fast continuous speech). The panel
    /// renders the FULL stored timeline; the cap only prevents a
    /// runaway session from growing unbounded. If this ever trips in
    /// production, spill to disk rather than clip the UI.
    private static let maxSavedEntryCount = 10_000
    private static let manualCommitByteThreshold = 67_200
    private static let minimumManualCommitByteCount = 4_800
    private static let targetSampleRate: Double = 24_000

    private let inputQueue = DispatchQueue(label: "RecappiMini.BackendRealtimeLiveCaptionTranscriber.input")
    private let stateQueue = DispatchQueue(label: "RecappiMini.BackendRealtimeLiveCaptionTranscriber.state")
    private let pendingLock = NSLock()
    private let onUpdate: @MainActor @Sendable (LiveCaptionSnapshot) -> Void
    private let client: RecappiAPIClient
    private let language: String
    private let mode: Mode

    private var webSocketTask: URLSessionWebSocketTask?
    private var isAcceptingInput = false
    private var pendingAudioBufferCount = 0
    private var lastPublishedSegments: [LiveCaptionSegment] = []
    private var transcriptTimeline: [TranscriptItemKey] = []
    private var transcriptItems: [TranscriptItemKey: TranscriptItem] = [:]
    private var pendingPreviousItemIDByKey: [TranscriptItemKey: String] = [:]
    private var fallbackSequence = 0
    private var hasUncommittedAudio = false
    private var uncommittedAudioByteCount = 0
    /// Translation-mode segment builder. nil for transcription mode.
    /// Owned by `stateQueue` (every access goes through stateQueue.sync).
    private var bilingualBuilder: BilingualSegmentBuilder?

    init(
        client: RecappiAPIClient,
        language: String,
        mode: Mode = .transcription,
        onUpdate: @escaping @MainActor @Sendable (LiveCaptionSnapshot) -> Void
    ) {
        self.client = client
        self.language = language
        self.mode = mode
        self.onUpdate = onUpdate
        if mode.isTranslation {
            self.bilingualBuilder = BilingualSegmentBuilder()
        }
    }

    func start() {
        Task { [weak self] in
            await self?.run()
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard reservePendingAudioBuffer() else { return }
        guard let audio = autoreleasepool(invoking: { Self.realtimePCMData(from: sampleBuffer) }),
              !audio.isEmpty else {
            releasePendingAudioBuffer()
            return
        }

        inputQueue.async { [weak self] in
            guard let self else { return }
            defer { self.releasePendingAudioBuffer() }
            guard self.isAcceptingInput else { return }
            self.sendAudio(audio)
        }
    }

    func stop(saveTo sessionDir: URL?) {
        inputQueue.sync {
            isAcceptingInput = false
            switch mode {
            case .transcription:
                commitPendingAudio(force: true)
            case .translation:
                // OpenAI translation endpoint forbids commit/clear and
                // accepts `session.close` for an explicit teardown. We
                // try `session.close` first, then fall back to dropping
                // the connection — both end the upstream session.
                sendEvent(["type": "session.close"])
            }
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
        }

        if let sessionDir {
            saveEntries(to: sessionDir)
        }
    }

    private func run() async {
        let preparingMessage = mode.isTranslation
            ? "Preparing bilingual live captions..."
            : "Preparing backend live captions..."
        await publish(.statusOnly(phase: .preparing, message: preparingMessage))

        do {
            let claim: OpenAIRealtimeSessionClaim
            switch mode {
            case .transcription:
                claim = try await client.createRealtimeTranscriptionSession(language: language)
            case .translation(let targetLanguage):
                claim = try await client.createRealtimeTranslationSession(
                    language: language,
                    targetLanguage: targetLanguage
                )
            }
            guard let url = URL(string: claim.websocketUrl) else {
                throw RecappiAPIError.invalidURL
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.setValue("\(claim.tokenType) \(claim.token)", forHTTPHeaderField: "Authorization")
            request.setValue(client.origin, forHTTPHeaderField: "Origin")

            let task = URLSession.shared.webSocketTask(with: request)
            inputQueue.sync {
                webSocketTask = task
                isAcceptingInput = true
                hasUncommittedAudio = false
                uncommittedAudioByteCount = 0
            }
            resetTranscriptState()
            task.resume()
            receiveLoop(task)

            // No trailing dots: compact mode just had a mojibake/`…`
            // regression and a bare status reads cleanly without
            // looking like a caption-truncation indicator.
            let listeningMessage = mode.isTranslation
                ? "Listening with backend bilingual"
                : "Listening with backend Realtime"
            await publish(.statusOnly(phase: .listening, message: listeningMessage))
        } catch {
            await publish(.statusOnly(phase: .failed, message: error.localizedDescription))
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            switch result {
            case .success(let message):
                self.consume(message)
                self.receiveLoop(task)
            case .failure(let error):
                self.publishFromCallback(.statusOnly(phase: .failed, message: error.localizedDescription))
            }
        }
    }

    private func consume(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let payload):
            data = payload
        @unknown default:
            data = nil
        }
        guard let data,
              let event = try? JSONDecoder().decode(RealtimeEvent.self, from: data) else {
            return
        }

        switch event.type {
        // Transcription mode events.
        case "input_audio_buffer.committed":
            registerCommittedItem(event.transcriptItemKey, previousItemID: event.previousItemID)
        case "conversation.item.input_audio_transcription.delta":
            if let snapshot = appendTranscriptDelta(event.delta, key: event.transcriptItemKey) {
                publishFromCallback(snapshot)
            }
        case "conversation.item.input_audio_transcription.completed":
            if let snapshot = completeTranscript(event.transcript, key: event.transcriptItemKey) {
                publishFromCallback(snapshot)
            }
        // Translation/bilingual mode events. The translation endpoint
        // is a continuous stream; we forward the source/target deltas
        // into `BilingualSegmentBuilder`, which decides finalize
        // boundaries from punctuation + silence.
        case "session.input_transcript.delta":
            if let delta = event.delta, !delta.isEmpty,
               let snapshot = ingestBilingualDelta(.source, text: delta) {
                publishFromCallback(snapshot)
            }
        case "session.output_transcript.delta":
            if let delta = event.delta, !delta.isEmpty,
               let snapshot = ingestBilingualDelta(.translation, text: delta) {
                publishFromCallback(snapshot)
            }
        case "error":
            let message = event.error?.message ?? "Backend Realtime failed."
            publishFromCallback(.statusOnly(phase: .failed, message: message))
        default:
            break
        }
    }

    private func ingestBilingualDelta(_ stream: BilingualStream, text: String) -> LiveCaptionSnapshot? {
        return stateQueue.sync { () -> LiveCaptionSnapshot? in
            guard let builder = bilingualBuilder else { return nil }
            builder.append(stream: stream, delta: text)
            let segments = builder.snapshot()
            guard segments != lastPublishedSegments else { return nil }
            lastPublishedSegments = segments
            let allFinal = segments.allSatisfy(\.isFinal)
            return LiveCaptionSnapshot(
                phase: .listening,
                segments: segments,
                allSegmentsFinal: allFinal,
                message: nil
            )
        }
    }

#if DEBUG
    func handleTranscriptDeltaForTesting(
        _ delta: String,
        itemID: String? = nil,
        contentIndex: Int? = nil
    ) -> LiveCaptionSnapshot? {
        appendTranscriptDelta(delta, key: .init(itemID: itemID, contentIndex: contentIndex))
    }

    func handleCommittedItemForTesting(itemID: String, previousItemID: String? = nil) {
        registerCommittedItem(.init(itemID: itemID, contentIndex: nil), previousItemID: previousItemID)
    }

    func handleTranscriptCompletionForTesting(
        _ transcript: String?,
        itemID: String? = nil,
        contentIndex: Int? = nil
    ) -> LiveCaptionSnapshot? {
        completeTranscript(transcript, key: .init(itemID: itemID, contentIndex: contentIndex))
    }

    func handleBilingualSourceDeltaForTesting(_ delta: String) -> LiveCaptionSnapshot? {
        ingestBilingualDelta(.source, text: delta)
    }

    func handleBilingualTranslationDeltaForTesting(_ delta: String) -> LiveCaptionSnapshot? {
        ingestBilingualDelta(.translation, text: delta)
    }
#endif

    private func appendTranscriptDelta(_ rawDelta: String?, key: TranscriptItemKey) -> LiveCaptionSnapshot? {
        guard let delta = rawDelta, !delta.isEmpty else { return nil }

        return stateQueue.sync { () -> LiveCaptionSnapshot? in
            let existing = ensureTranscriptItemLocked(key)
            guard !existing.isFinal else {
                NSLog(
                    "[Recappi] [realtime-stream] discarded_late_delta item_id=%@ content_index=%d delta_chars=%d reason=after_completed",
                    key.itemID,
                    key.contentIndex,
                    delta.count
                )
                return nil
            }
            transcriptItems[key] = existing.appending(delta)
            return publishTimelineSnapshotLocked()
        }
    }

    private func completeTranscript(_ rawTranscript: String?, key: TranscriptItemKey) -> LiveCaptionSnapshot? {
        return stateQueue.sync { () -> LiveCaptionSnapshot? in
            let existing = ensureTranscriptItemLocked(key)
            let text = (rawTranscript ?? existing.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            transcriptItems[key] = existing.replacingText(text, isFinal: true)
            return publishTimelineSnapshotLocked()
        }
    }

    private func registerCommittedItem(_ key: TranscriptItemKey, previousItemID: String?) {
        stateQueue.sync {
            let existing = ensureTranscriptItemLocked(key)
            transcriptItems[key] = existing
            guard let previousItemID, !previousItemID.isEmpty else { return }
            if moveTranscriptItemLocked(key, afterItemID: previousItemID) {
                pendingPreviousItemIDByKey[key] = nil
            } else {
                pendingPreviousItemIDByKey[key] = previousItemID
            }
        }
    }

    private func resetTranscriptState() {
        stateQueue.sync {
            lastPublishedSegments = []
            transcriptTimeline = []
            transcriptItems = [:]
            pendingPreviousItemIDByKey = [:]
            fallbackSequence = 0
        }
    }

    private func ensureTranscriptItemLocked(_ key: TranscriptItemKey) -> TranscriptItem {
        if let item = transcriptItems[key] {
            return item
        }

        fallbackSequence += 1
        let item = TranscriptItem(text: "", isFinal: false, sequence: fallbackSequence)
        transcriptItems[key] = item
        transcriptTimeline.append(key)
        return item
    }

    @discardableResult
    private func moveTranscriptItemLocked(_ key: TranscriptItemKey, afterItemID previousItemID: String) -> Bool {
        guard let currentIndex = transcriptTimeline.firstIndex(of: key),
              let previousIndex = transcriptTimeline.lastIndex(where: { $0.itemID == previousItemID }) else {
            return false
        }

        let removed = transcriptTimeline.remove(at: currentIndex)
        let adjustedPreviousIndex = currentIndex < previousIndex ? previousIndex - 1 : previousIndex
        transcriptTimeline.insert(removed, at: min(adjustedPreviousIndex + 1, transcriptTimeline.count))
        return true
    }

    private func resolvePendingPlacementsLocked(afterItemID itemID: String) {
        let pendingKeys = pendingPreviousItemIDByKey
            .filter { $0.value == itemID }
            .map(\.key)

        for key in pendingKeys where moveTranscriptItemLocked(key, afterItemID: itemID) {
            pendingPreviousItemIDByKey[key] = nil
        }
    }

    private func publishTimelineSnapshotLocked() -> LiveCaptionSnapshot? {
        resolveAllPendingPlacementsLocked()
        trimTranscriptTimelineLocked()

        let segments = displaySegmentsLocked()
        guard !segments.isEmpty else { return nil }

        if segments == lastPublishedSegments { return nil }
        lastPublishedSegments = segments

        let allFinal = segments.allSatisfy(\.isFinal)
        return LiveCaptionSnapshot(
            phase: .listening,
            segments: segments,
            allSegmentsFinal: allFinal,
            message: nil
        )
    }

    private func displaySegmentsLocked() -> [LiveCaptionSegment] {
        struct DisplaySegment {
            let id: String
            var sourceText: String
            var isFinal: Bool
            let sequence: Int

            var liveCaptionSegment: LiveCaptionSegment {
                LiveCaptionSegment(
                    id: id,
                    sourceText: sourceText,
                    translatedText: nil,
                    isFinal: isFinal,
                    sequence: sequence
                )
            }
        }

        var segments: [LiveCaptionSegment] = []
        var current: DisplaySegment?

        for key in transcriptTimeline {
            guard let item = transcriptItems[key] else { continue }
            let normalized = Self.normalizedSegmentText(item.text)
            guard !normalized.isEmpty else { continue }

            if var active = current {
                if Self.shouldStartNewDisplaySegment(
                    after: active.sourceText,
                    beforeAppending: normalized
                ) {
                    segments.append(active.liveCaptionSegment)
                    current = DisplaySegment(
                        id: Self.segmentIdentifier(for: key),
                        sourceText: normalized,
                        isFinal: item.isFinal,
                        sequence: item.sequence
                    )
                } else {
                    Self.appendDisplayText(normalized, to: &active.sourceText)
                    active.isFinal = active.isFinal && item.isFinal
                    current = active
                }
            } else {
                current = DisplaySegment(
                    id: Self.segmentIdentifier(for: key),
                    sourceText: normalized,
                    isFinal: item.isFinal,
                    sequence: item.sequence
                )
            }
        }

        if let current {
            segments.append(current.liveCaptionSegment)
        }
        return segments
    }

    /// Stable id used by the UI / translation cache. Combining
    /// `item_id` and `content_index` keeps the id unique even when one
    /// Realtime item carries multiple content slots.
    private static func segmentIdentifier(for key: TranscriptItemKey) -> String {
        key.contentIndex == 0
            ? key.itemID
            : "\(key.itemID)#\(key.contentIndex)"
    }

    /// Collapse runs of whitespace into single spaces. Segment-level
    /// rendering joins segments with `\n` (or richer attribute breaks)
    /// in the UI layer, so each segment text stays single-line.
    private static func normalizedSegmentText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func shouldStartNewDisplaySegment(
        after text: String,
        beforeAppending fragment: String
    ) -> Bool {
        if shouldStartNewDisplaySegmentAfterSentenceBoundary(text) {
            return true
        }

        let proposedLength = text.count + fragment.count
        let softLimit = displaySegmentSoftLimit(for: text + fragment)
        return text.count >= softLimit || proposedLength >= softLimit * 2
    }

    private static func shouldStartNewDisplaySegmentAfterSentenceBoundary(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return last.isLiveCaptionSentenceEnding
    }

    private static func displaySegmentSoftLimit(for text: String) -> Int {
        text.contains(where: \.isCJK) ? 72 : 140
    }

    private static func appendDisplayText(_ fragment: String, to result: inout String) {
        guard !fragment.isEmpty else { return }
        guard let previous = result.last, let next = fragment.first else {
            result.append(fragment)
            return
        }

        if shouldInsertDisplaySpace(between: previous, and: next) {
            result.append(" ")
        }
        result.append(fragment)
    }

    private static func shouldInsertDisplaySpace(between previous: Character, and next: Character) -> Bool {
        if previous.isWhitespace || next.isWhitespace { return false }
        if next.isPunctuation || next.isSymbol { return false }
        if previous.isPunctuation || previous.isSymbol { return true }
        if previous.isCJK || next.isCJK { return false }
        return true
    }

    private func sendAudio(_ data: Data) {
        // OpenAI uses different event names per session shape:
        //   - transcription: `input_audio_buffer.append`
        //   - translation:   `session.input_audio_buffer.append`
        // and translation rejects any `commit`/`clear` we used to send.
        let eventType = mode.isTranslation
            ? "session.input_audio_buffer.append"
            : "input_audio_buffer.append"
        sendEvent([
            "type": eventType,
            "audio": data.base64EncodedString(),
        ])
        guard !mode.isTranslation else {
            // Translation streams continuously; no manual commit.
            return
        }
        hasUncommittedAudio = true
        uncommittedAudioByteCount += data.count
        if uncommittedAudioByteCount >= Self.manualCommitByteThreshold {
            commitPendingAudio()
        }
    }

    private func resolveAllPendingPlacementsLocked() {
        let knownItemIDs = Set(transcriptTimeline.map(\.itemID))
        knownItemIDs.forEach { resolvePendingPlacementsLocked(afterItemID: $0) }
    }

    private func commitPendingAudio(force: Bool = false) {
        guard hasUncommittedAudio else { return }
        guard force || uncommittedAudioByteCount >= Self.minimumManualCommitByteCount else { return }
        sendEvent(["type": "input_audio_buffer.commit"])
        hasUncommittedAudio = false
        uncommittedAudioByteCount = 0
    }

    private func sendEvent(_ event: [String: Any]) {
        guard let task = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        task.send(.string(text)) { error in
            guard let error else { return }
            NSLog("[Recappi] backend realtime live captions send failed: %@", error.localizedDescription)
        }
    }

    private func publish(_ snapshot: LiveCaptionSnapshot) async {
        await MainActor.run {
            onUpdate(snapshot)
        }
    }

    private func publishFromCallback(_ snapshot: LiveCaptionSnapshot) {
        let onUpdate = onUpdate
        Task { @MainActor in
            onUpdate(snapshot)
        }
    }

    private func saveEntries(to sessionDir: URL) {
        let finalEntries = stateQueue.sync {
            if let builder = bilingualBuilder {
                builder.finalizePending()
                let orderedEntries = builder.snapshot()
                    .suffix(Self.maxSavedEntryCount)
                    .compactMap { segment -> LiveCaptionEntry? in
                        let text = [segment.sourceText, segment.translatedText]
                            .compactMap { value -> String? in
                                let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                return trimmed.isEmpty ? nil : trimmed
                            }
                            .joined(separator: "\n")
                        guard !text.isEmpty else { return nil }
                        return LiveCaptionEntry(
                            text: text,
                            isFinal: true,
                            startedAtMs: nil,
                            endedAtMs: nil
                        )
                    }
                return Array(orderedEntries)
            }

            let orderedEntries = transcriptTimeline
                .compactMap { transcriptItems[$0] }
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .suffix(Self.maxSavedEntryCount)
                .map {
                    LiveCaptionEntry(
                        text: $0.text,
                        isFinal: $0.isFinal,
                        startedAtMs: nil,
                        endedAtMs: nil
                    )
                }
            let finalEntries = orderedEntries.filter(\.isFinal)
            if !finalEntries.isEmpty { return finalEntries }
            return Array(orderedEntries.suffix(1))
        }
        guard !finalEntries.isEmpty,
              let data = try? JSONEncoder().encode(finalEntries) else {
            return
        }
        let url = sessionDir.appendingPathComponent("live-captions.json")
        try? data.write(to: url, options: .atomic)
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

    private func trimTranscriptTimelineLocked() {
        guard transcriptTimeline.count > Self.maxSavedEntryCount else { return }
        let removed = transcriptTimeline.prefix(transcriptTimeline.count - Self.maxSavedEntryCount)
        removed.forEach { transcriptItems[$0] = nil }
        transcriptTimeline.removeFirst(transcriptTimeline.count - Self.maxSavedEntryCount)
    }

    private static func realtimePCMData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let source = floatingPCMBuffer(from: sampleBuffer),
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: true
              ) else {
            return nil
        }

        guard let converter = AVAudioConverter(from: source.format, to: targetFormat) else {
            return nil
        }
        let ratio = targetSampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * ratio) + 16)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        let inputState = ConverterInputState(source: source)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            inputState.next(status: status)
        }
        guard error == nil,
              converted.frameLength > 0,
              let data = converted.int16ChannelData else {
            return nil
        }

        let byteCount = Int(converted.frameLength) * Int(converted.format.streamDescription.pointee.mBytesPerFrame)
        return Data(bytes: data[0], count: byteCount)
    }

    private static func floatingPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
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
              let buffer = AVAudioPCMBuffer(
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
              let channels = buffer.floatChannelData else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        if isFloat, asbd.mBitsPerChannel == 32 {
            let sampleCount = min(totalLength / MemoryLayout<Float>.size, frameCount * channelCount)
            raw.withMemoryRebound(to: Float.self, capacity: sampleCount) { source in
                copySamples(
                    source: source,
                    sampleCount: sampleCount,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    isNonInterleaved: isNonInterleaved,
                    into: channels
                )
            }
        } else if asbd.mBitsPerChannel == 16 {
            let sampleCount = min(totalLength / MemoryLayout<Int16>.size, frameCount * channelCount)
            raw.withMemoryRebound(to: Int16.self, capacity: sampleCount) { source in
                for frame in 0..<frameCount {
                    for channel in 0..<channelCount {
                        let index = sourceIndex(
                            frame: frame,
                            channel: channel,
                            frameCount: frameCount,
                            channelCount: channelCount,
                            isNonInterleaved: isNonInterleaved
                        )
                        channels[channel][frame] = index < sampleCount ? Float(source[index]) / 32768 : 0
                    }
                }
            }
        } else {
            return nil
        }

        return buffer
    }

    private static func copySamples(
        source: UnsafePointer<Float>,
        sampleCount: Int,
        frameCount: Int,
        channelCount: Int,
        isNonInterleaved: Bool,
        into channels: UnsafePointer<UnsafeMutablePointer<Float>>
    ) {
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let index = sourceIndex(
                    frame: frame,
                    channel: channel,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    isNonInterleaved: isNonInterleaved
                )
                channels[channel][frame] = index < sampleCount ? source[index] : 0
            }
        }
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

private struct RealtimeEvent: Decodable {
    let type: String
    let itemID: String?
    let previousItemID: String?
    let contentIndex: Int?
    let delta: String?
    let transcript: String?
    let error: RealtimeError?

    var transcriptItemKey: TranscriptItemKey {
        .init(itemID: itemID, contentIndex: contentIndex)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case itemID = "item_id"
        case previousItemID = "previous_item_id"
        case contentIndex = "content_index"
        case delta
        case transcript
        case error
    }
}

private struct RealtimeError: Decodable {
    let message: String?
}

private struct TranscriptItem {
    let text: String
    let isFinal: Bool
    let sequence: Int

    func appending(_ delta: String) -> TranscriptItem {
        .init(text: text + delta, isFinal: false, sequence: sequence)
    }

    func replacingText(_ text: String, isFinal: Bool) -> TranscriptItem {
        .init(text: text, isFinal: isFinal, sequence: sequence)
    }
}

private struct TranscriptItemKey: Hashable {
    private static let fallbackItemID = "__recappi_transcript_item"

    let itemID: String
    let contentIndex: Int

    init(itemID: String?, contentIndex: Int?) {
        self.itemID = itemID ?? Self.fallbackItemID
        self.contentIndex = contentIndex ?? 0
    }
}

/// Which side of a bilingual delta we just received.
private enum BilingualStream {
    case source
    case translation
}

/// Continuous-stream segmenter for bilingual translation mode. The
/// OpenAI translation endpoint emits source / target deltas without
/// `item_id` or `final` markers, so the client decides finalize
/// boundaries from sentence punctuation + a silence threshold.
///
/// Output shape:
/// - The "active" tail (in-progress, isFinal=false) is the last
///   element of `snapshot()`; finalized utterances precede it.
/// - Each finalized segment carries a stable id (`bilingual-N`) so the
///   UI can stably render & cache.
/// - `sourceText` and `translatedText` are merged by id. We wait for
///   both streams to look sentence-complete before finalizing because
///   production smoke showed translation deltas can trail the source.
private final class BilingualSegmentBuilder {
    /// Min chars in either buffer before a sentence-ending punctuation
    /// is taken as a real segment boundary. Avoids breaking on a stray
    /// "Mr." or short interjections.
    private static let minSegmentBoundaryChars = 12
    private static let softCapASCIIChars = 220
    private static let softCapCJKChars = 60

    private struct Pending {
        var sourceText: String = ""
        var translatedText: String = ""
        var isFinal: Bool = false

        var hasContent: Bool {
            !sourceText.isEmpty || !translatedText.isEmpty
        }
    }

    private var finalized: [LiveCaptionSegment] = []
    private var pending = Pending()
    private var nextSequence = 0

    func append(stream: BilingualStream, delta: String) {
        switch stream {
        case .source:
            pending.sourceText += delta
        case .translation:
            pending.translatedText += delta
        }

        finalizeCompletedBoundaries()
    }

    private func finalizeCompletedBoundaries() {
        while true {
            if let sourceBoundary = Self.completedSentenceBoundary(in: pending.sourceText),
               let translationBoundary = Self.completedSentenceBoundary(in: pending.translatedText),
               sourceBoundary.segmentText.count >= Self.minSegmentBoundaryChars(for: sourceBoundary.segmentText),
               translationBoundary.segmentText.count >= Self.minSegmentBoundaryChars(for: translationBoundary.segmentText) {
                finalizeBoundary(sourceBoundary, translationBoundary)
                continue
            }

            if let sourceBoundary = Self.forceBoundary(in: pending.sourceText),
               let translationBoundary = Self.forceBoundary(in: pending.translatedText) {
                finalizeBoundary(sourceBoundary, translationBoundary)
                continue
            }

            return
        }
    }

    /// Force-finalize the active segment, e.g. when the session is
    /// stopping. Optional helper for `stop()` flush paths.
    func finalizePending() {
        guard pending.hasContent else { return }
        let segment = LiveCaptionSegment(
            id: "bilingual-\(nextSequence)",
            sourceText: pending.sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
            translatedText: pending.translatedText.trimmingCharacters(in: .whitespacesAndNewlines),
            isFinal: true,
            sequence: nextSequence
        )
        finalized.append(segment)
        nextSequence += 1
        pending = Pending()
    }

    private func finalizeBoundary(_ sourceBoundary: TextBoundary, _ translationBoundary: TextBoundary) {
        let segment = LiveCaptionSegment(
            id: "bilingual-\(nextSequence)",
            sourceText: sourceBoundary.segmentText,
            translatedText: translationBoundary.segmentText,
            isFinal: true,
            sequence: nextSequence
        )
        finalized.append(segment)
        nextSequence += 1
        pending.sourceText = sourceBoundary.remainder
        pending.translatedText = translationBoundary.remainder
        pending.isFinal = false
    }

    func snapshot() -> [LiveCaptionSegment] {
        var segments = finalized
        if pending.hasContent {
            segments.append(
                LiveCaptionSegment(
                    id: "bilingual-\(nextSequence)",
                    sourceText: pending.sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
                    translatedText: pending.translatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                    isFinal: false,
                    sequence: nextSequence
                )
            )
        }
        return segments
    }

    private struct TextBoundary {
        let segmentText: String
        let remainder: String
    }

    private static func minSegmentBoundaryChars(for text: String) -> Int {
        text.contains(where: \.isCJK) ? 4 : minSegmentBoundaryChars
    }

    private static func completedSentenceBoundary(in text: String) -> TextBoundary? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex {
            let character = trimmed[cursor]
            guard character.isLiveCaptionSentenceEnding else {
                cursor = trimmed.index(after: cursor)
                continue
            }

            let next = trimmed.index(after: cursor)
            if next == trimmed.endIndex {
                return TextBoundary(segmentText: trimmed, remainder: "")
            }

            let nextCharacter = trimmed[next]
            if nextCharacter.isWhitespace || nextCharacter.isCJK {
                let segment = String(trimmed[..<next])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let remainder = String(trimmed[next...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return TextBoundary(segmentText: segment, remainder: remainder)
            }
            cursor = next
        }
        return nil
    }

    private static func forceBoundary(in text: String) -> TextBoundary? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = trimmed.contains(where: \.isCJK) ? softCapCJKChars : softCapASCIIChars
        guard trimmed.count >= limit else { return nil }

        if let lastSentenceEnd = trimmed.lastIndex(where: \.isLiveCaptionSentenceEnding) {
            let afterEnd = trimmed.index(after: lastSentenceEnd)
            let segment = String(trimmed[..<afterEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let remainder = String(trimmed[afterEnd...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty, !remainder.isEmpty {
                return TextBoundary(segmentText: segment, remainder: remainder)
            }
        }

        let cutIndex = preferredHardCutIndex(in: trimmed, limit: limit)
        let segment = String(trimmed[..<cutIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = String(trimmed[cutIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty, !remainder.isEmpty else { return nil }
        return TextBoundary(segmentText: segment, remainder: remainder)
    }

    private static func preferredHardCutIndex(in text: String, limit: Int) -> String.Index {
        let target = text.index(text.startIndex, offsetBy: limit)
        guard !text.contains(where: \.isCJK) else { return target }

        var cursor = target
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            if text[previous].isWhitespace {
                return cursor
            }
            cursor = previous
        }
        return target
    }
}

private extension Character {
    var isLiveCaptionSentenceEnding: Bool {
        [".", "!", "?", "。", "！", "？"].contains(self)
    }

    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x3040...0x30FF).contains(scalar.value) ||
                (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}

private final class ConverterInputState: @unchecked Sendable {
    private let source: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didProvideInput = false

    init(source: AVAudioPCMBuffer) {
        self.source = source
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !didProvideInput else {
            status.pointee = .noDataNow
            return nil
        }
        didProvideInput = true
        status.pointee = .haveData
        return source
    }
}
