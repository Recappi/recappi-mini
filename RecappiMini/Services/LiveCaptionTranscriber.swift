import AVFoundation
import CoreMedia
import Foundation
import Speech

struct LiveCaptionSnapshot: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case preparing
        case listening
        case unavailable
        case failed
    }

    let phase: Phase
    let text: String?
    let isFinal: Bool
    let message: String?
}

struct LiveCaptionEntry: Codable, Equatable, Sendable {
    let text: String
    let isFinal: Bool
    let startedAtMs: Int?
    let endedAtMs: Int?
}

@available(macOS 26.0, *)
final class LiveCaptionTranscriber: @unchecked Sendable {
    private let inputQueue = DispatchQueue(label: "RecappiMini.LiveCaptionTranscriber.input")
    private let onUpdate: @MainActor @Sendable (LiveCaptionSnapshot) -> Void

    private var continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var entries: [LiveCaptionEntry] = []
    private var isAcceptingInput = false

    init(onUpdate: @escaping @MainActor @Sendable (LiveCaptionSnapshot) -> Void) {
        self.onUpdate = onUpdate
    }

    func start(localeIdentifier: String) {
        analysisTask = Task { [weak self] in
            await self?.run(localeIdentifier: localeIdentifier)
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let input = Self.analyzerInput(from: sampleBuffer) else { return }
        inputQueue.async { [weak self] in
            guard let self, self.isAcceptingInput else { return }
            self.continuation?.yield(input)
        }
    }

    func stop(saveTo sessionDir: URL?) {
        inputQueue.async { [weak self] in
            guard let self else { return }
            self.isAcceptingInput = false
            self.continuation?.finish()
        }

        analysisTask?.cancel()
        resultsTask?.cancel()

        if let sessionDir {
            saveEntries(to: sessionDir)
        }

        Task { [analyzer] in
            await analyzer?.cancelAndFinishNow()
        }
    }

    private func run(localeIdentifier: String) async {
        await publish(.init(phase: .preparing, text: nil, isFinal: false, message: "Preparing live captions…"))

        guard SpeechTranscriber.isAvailable else {
            await publish(.init(phase: .unavailable, text: nil, isFinal: false, message: "Live captions are not available on this Mac."))
            return
        }

        do {
            let requestedLocale = Locale(identifier: localeIdentifier)
            let requestedSupportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
            let fallbackSupportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
            let locale = requestedSupportedLocale ?? fallbackSupportedLocale ?? requestedLocale
            let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
            let modules: [any SpeechModule] = [transcriber]

            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                await publish(.init(phase: .preparing, text: nil, isFinal: false, message: "Downloading speech model…"))
                try await request.downloadAndInstall()
            }

            let analyzer = SpeechAnalyzer(
                modules: modules,
                options: .init(priority: .utility, modelRetention: .whileInUse)
            )
            self.analyzer = analyzer

            var streamContinuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
            let stream = AsyncThrowingStream<AnalyzerInput, Error> { continuation in
                streamContinuation = continuation
            }
            inputQueue.sync {
                continuation = streamContinuation
                isAcceptingInput = true
            }

            resultsTask = Task { [weak self, transcriber] in
                do {
                    for try await result in transcriber.results {
                        await self?.handle(result)
                    }
                } catch {
                    await self?.publish(.init(phase: .failed, text: nil, isFinal: false, message: error.localizedDescription))
                }
            }

            try await analyzer.prepareToAnalyze(in: nil)
            await publish(.init(phase: .listening, text: nil, isFinal: false, message: "Listening for live captions…"))
            try await analyzer.start(inputSequence: stream)
        } catch is CancellationError {
            return
        } catch {
            await publish(.init(phase: .failed, text: nil, isFinal: false, message: error.localizedDescription))
        }
    }

    private func handle(_ result: SpeechTranscriber.Result) async {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let entry = LiveCaptionEntry(
            text: text,
            isFinal: result.isFinal,
            startedAtMs: result.range.start.milliseconds,
            endedAtMs: result.range.end.milliseconds
        )
        entries.append(entry)

        await publish(.init(phase: .listening, text: text, isFinal: result.isFinal, message: nil))
    }

    private func publish(_ snapshot: LiveCaptionSnapshot) async {
        await MainActor.run {
            onUpdate(snapshot)
        }
    }

    private func saveEntries(to sessionDir: URL) {
        let finalEntries = entries.filter(\.isFinal)
        guard !finalEntries.isEmpty,
              let data = try? JSONEncoder().encode(finalEntries) else {
            return
        }
        let url = sessionDir.appendingPathComponent("live-captions.json")
        try? data.write(to: url, options: .atomic)
    }

    private static func analyzerInput(from sampleBuffer: CMSampleBuffer) -> AnalyzerInput? {
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

        if isFloat, asbd.mBitsPerChannel == 32 {
            let sampleCount = min(totalLength / MemoryLayout<Float>.size, frameCount * channelCount)
            raw.withMemoryRebound(to: Float.self, capacity: sampleCount) { source in
                copyInterleavedSamples(source, frameCount: frameCount, channelCount: channelCount, to: channels)
            }
        } else if asbd.mBitsPerChannel == 16 {
            let sampleCount = min(totalLength / MemoryLayout<Int16>.size, frameCount * channelCount)
            raw.withMemoryRebound(to: Int16.self, capacity: sampleCount) { source in
                for frame in 0..<frameCount {
                    for channel in 0..<channelCount {
                        let index = (frame * channelCount) + channel
                        channels[channel][frame] = index < sampleCount ? Float(source[index]) / 32768 : 0
                    }
                }
            }
        } else {
            return nil
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let startTime = timestamp.isValid ? timestamp : nil
        return AnalyzerInput(buffer: pcmBuffer, bufferStartTime: startTime)
    }

    private static func copyInterleavedSamples(
        _ source: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        to channels: UnsafePointer<UnsafeMutablePointer<Float>>
    ) {
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                channels[channel][frame] = source[(frame * channelCount) + channel]
            }
        }
    }
}

private extension CMTime {
    var milliseconds: Int? {
        guard isValid, seconds.isFinite else { return nil }
        return Int((seconds * 1000).rounded())
    }
}
