import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import Foundation

final class BackendRealtimeLiveCaptionTranscriber: NSObject, @unchecked Sendable {
    private static let maxPendingAudioBuffers = 8
    private static let maxSavedEntryCount = 240
    private static let manualCommitByteThreshold = 67_200
    private static let minimumManualCommitByteCount = 4_800
    private static let targetSampleRate: Double = 24_000

    private let inputQueue = DispatchQueue(label: "RecappiMini.BackendRealtimeLiveCaptionTranscriber.input")
    private let stateQueue = DispatchQueue(label: "RecappiMini.BackendRealtimeLiveCaptionTranscriber.state")
    private let pendingLock = NSLock()
    private let onUpdate: @MainActor @Sendable (LiveCaptionSnapshot) -> Void
    private let client: RecappiAPIClient
    private let language: String

    private var webSocketTask: URLSessionWebSocketTask?
    private var isAcceptingInput = false
    private var pendingAudioBufferCount = 0
    private var entries: [LiveCaptionEntry] = []
    private var latestPartialEntry: LiveCaptionEntry?
    private var lastPublishedText: String?
    private var hasUncommittedAudio = false
    private var uncommittedAudioByteCount = 0

    init(
        client: RecappiAPIClient,
        language: String,
        onUpdate: @escaping @MainActor @Sendable (LiveCaptionSnapshot) -> Void
    ) {
        self.client = client
        self.language = language
        self.onUpdate = onUpdate
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
            commitPendingAudio(force: true)
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
        }

        if let sessionDir {
            saveEntries(to: sessionDir)
        }
    }

    private func run() async {
        await publish(.init(
            phase: .preparing,
            text: nil,
            isFinal: false,
            message: "Preparing backend live captions..."
        ))

        do {
            let claim = try await client.createRealtimeTranscriptionSession(language: language)
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
            task.resume()
            receiveLoop(task)

            await publish(.init(
                phase: .listening,
                text: nil,
                isFinal: false,
                message: "Listening with backend Realtime..."
            ))
        } catch {
            await publish(.init(
                phase: .failed,
                text: nil,
                isFinal: false,
                message: error.localizedDescription
            ))
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
                self.publishFromCallback(.init(
                    phase: .failed,
                    text: nil,
                    isFinal: false,
                    message: error.localizedDescription
                ))
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
        case "conversation.item.input_audio_transcription.delta":
            publishText(event.delta, isFinal: false)
        case "conversation.item.input_audio_transcription.completed":
            publishText(event.transcript, isFinal: true)
        case "error":
            let message = event.error?.message ?? "Backend Realtime failed."
            publishFromCallback(.init(phase: .failed, text: nil, isFinal: false, message: message))
        default:
            break
        }
    }

    private func publishText(_ rawText: String?, isFinal: Bool) {
        let text = rawText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }

        stateQueue.async { [weak self] in
            guard let self else { return }
            if self.lastPublishedText == text, !isFinal {
                return
            }
            self.lastPublishedText = text
            let entry = LiveCaptionEntry(
                text: text,
                isFinal: isFinal,
                startedAtMs: nil,
                endedAtMs: nil
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

        publishFromCallback(.init(phase: .listening, text: text, isFinal: isFinal, message: nil))
    }

    private func sendAudio(_ data: Data) {
        sendEvent([
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ])
        hasUncommittedAudio = true
        uncommittedAudioByteCount += data.count

        if uncommittedAudioByteCount >= Self.manualCommitByteThreshold {
            commitPendingAudio()
        }
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
            let finals = entries.filter(\.isFinal)
            if !finals.isEmpty { return finals }
            return latestPartialEntry.map { [$0] } ?? []
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

    private func trimEntriesLocked() {
        guard entries.count > Self.maxSavedEntryCount else { return }
        entries.removeFirst(entries.count - Self.maxSavedEntryCount)
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
    let delta: String?
    let transcript: String?
    let error: RealtimeError?
}

private struct RealtimeError: Decodable {
    let message: String?
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
