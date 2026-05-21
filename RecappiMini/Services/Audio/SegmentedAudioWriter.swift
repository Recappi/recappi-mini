import AVFoundation
import CoreMedia
import Foundation

struct CaptureStreamFormat: Equatable {
    let sampleRate: Int
    let channelCount: Int

    init(sampleRate: Int, channelCount: Int) {
        self.sampleRate = max(sampleRate, 1)
        self.channelCount = min(max(channelCount, 1), 2)
    }

    init(sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw RecorderError.invalidAudioFormat
        }

        self.init(
            sampleRate: Int(asbd.pointee.mSampleRate.rounded()),
            channelCount: Int(asbd.pointee.mChannelsPerFrame)
        )
    }

    var recommendedBitRate: Int {
        min(max(channelCount, 1) * 64_000, 256_000)
    }
}

private final class UncheckedAssetWriterRef: @unchecked Sendable {
    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}

final class SegmentedAudioWriter: @unchecked Sendable {
    private let finalURL: URL
    private let processingQueue: DispatchQueue
    private var activeWriter: AVAssetWriter?
    private var activeInput: AVAssetWriterInput?
    private var activeFormat: CaptureStreamFormat?
    private var activeSessionStarted = false
    private var segmentURLs: [URL] = []
    private var segmentIndex = 0
    private var pendingFinalizationCount = 0
    private var pendingError: Error?
    private var finishContinuation: CheckedContinuation<URL?, Error>?

    init(finalURL: URL, processingQueue: DispatchQueue) {
        self.finalURL = finalURL
        self.processingQueue = processingQueue
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        append(sampleBuffer, muted: false)
    }

    func append(_ sampleBuffer: CMSampleBuffer, muted: Bool) {
        guard finishContinuation == nil else { return }

        do {
            if muted {
                Self.zeroAudioData(in: sampleBuffer)
            }
            let streamFormat = try CaptureStreamFormat(sampleBuffer: sampleBuffer)

            if activeFormat != streamFormat || activeWriter == nil || activeInput == nil {
                finishActiveSegment()
                try startSegment(for: sampleBuffer, format: streamFormat)
            }

            guard let writer = activeWriter, let input = activeInput else { return }

            if !activeSessionStarted {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                activeSessionStarted = true
            }

            guard writer.status == .writing else {
                if writer.status == .failed || writer.status == .cancelled {
                    pendingError = pendingError ?? writer.error ?? RecorderError.failedToAppendAudio
                }
                return
            }

            guard input.isReadyForMoreMediaData else { return }

            if !input.append(sampleBuffer) {
                pendingError = pendingError ?? writer.error ?? RecorderError.failedToAppendAudio
            }
        } catch {
            pendingError = pendingError ?? error
        }
    }

    private static func zeroAudioData(in sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { return }
        memset(dataPointer, 0, totalLength)
    }

    func finishWriting() async throws -> URL? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            processingQueue.async {
                guard self.finishContinuation == nil else {
                    continuation.resume(throwing: RecorderError.finishAlreadyRequested)
                    return
                }

                self.finishContinuation = continuation
                self.finishActiveSegment()
                self.completeFinishIfPossible()
            }
        }
    }

    private func startSegment(for sampleBuffer: CMSampleBuffer, format: CaptureStreamFormat) throws {
        let segmentURL = makeSegmentURL(index: segmentIndex)
        segmentIndex += 1

        let fileType = Self.fileType(for: segmentURL)
        let settings = Self.outputSettings(for: format, fileType: fileType)
        let writer = try AVAssetWriter(url: segmentURL, fileType: fileType)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: settings,
            sourceFormatHint: sampleBuffer.formatDescription
        )
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw RecorderError.failedToCreateAudioInput
        }

        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.failedToStartWriter
        }

        activeWriter = writer
        activeInput = input
        activeFormat = format
        activeSessionStarted = false
        segmentURLs.append(segmentURL)
    }

    private func finishActiveSegment() {
        guard let writer = activeWriter, let input = activeInput else { return }

        activeWriter = nil
        activeInput = nil
        activeFormat = nil
        activeSessionStarted = false

        input.markAsFinished()
        pendingFinalizationCount += 1

        let writerRef = UncheckedAssetWriterRef(writer)
        writer.finishWriting { [weak self, writerRef] in
            guard let self else { return }
            let status = writerRef.writer.status
            let error = writerRef.writer.error

            self.processingQueue.async {
                if status == .failed || status == .cancelled {
                    self.pendingError = self.pendingError ?? error ?? RecorderError.failedToFinalizeSegment
                }
                self.pendingFinalizationCount -= 1
                self.completeFinishIfPossible()
            }
        }
    }

    private func completeFinishIfPossible() {
        guard pendingFinalizationCount == 0 else { return }
        guard let continuation = finishContinuation else { return }

        finishContinuation = nil

        if let error = pendingError {
            continuation.resume(throwing: error)
            return
        }

        Task {
            do {
                let finalizedURL = try await finalizeSegments()
                continuation.resume(returning: finalizedURL)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func finalizeSegments() async throws -> URL? {
        guard !segmentURLs.isEmpty else { return nil }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }

        if segmentURLs.count == 1 {
            try fileManager.moveItem(at: segmentURLs[0], to: finalURL)
            return finalURL
        }

        let outputFileType = Self.fileType(for: finalURL)
        if outputFileType == .caf {
            try Self.concatenateCAFSegments(segmentURLs, to: finalURL)
            for segmentURL in segmentURLs {
                try? fileManager.removeItem(at: segmentURL)
            }
            return finalURL
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecorderError.exportFailed
        }

        var cursor = CMTime.zero
        for segmentURL in segmentURLs {
            let asset = AVURLAsset(url: segmentURL)
            let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let sourceTrack = sourceTracks.first else {
                throw RecorderError.exportFailed
            }

            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            try track.insertTimeRange(range, of: sourceTrack, at: cursor)
            cursor = CMTimeAdd(cursor, duration)
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw RecorderError.exportFailed
        }

        try await exporter.export(to: finalURL, as: outputFileType)

        for segmentURL in segmentURLs {
            try? fileManager.removeItem(at: segmentURL)
        }

        return finalURL
    }

    private func makeSegmentURL(index: Int) -> URL {
        let baseName = finalURL.deletingPathExtension().lastPathComponent
        let ext = finalURL.pathExtension.isEmpty ? "m4a" : finalURL.pathExtension
        let segmentName = "\(baseName)-segment-\(String(format: "%03d", index)).\(ext)"
        return finalURL.deletingLastPathComponent().appendingPathComponent(segmentName)
    }

    private static func fileType(for url: URL) -> AVFileType {
        url.pathExtension.lowercased() == "caf" ? .caf : .m4a
    }

    private static func outputSettings(
        for format: CaptureStreamFormat,
        fileType: AVFileType
    ) -> [String: Any] {
        if fileType == .caf {
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }

        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: format.recommendedBitRate,
        ]
    }

    private static func concatenateCAFSegments(_ segmentURLs: [URL], to finalURL: URL) throws {
        guard let firstURL = segmentURLs.first else { return }
        let firstFile = try AVAudioFile(forReading: firstURL)
        guard let fileFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: firstFile.fileFormat.sampleRate,
            channels: firstFile.fileFormat.channelCount,
            interleaved: true
        ),
            let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: firstFile.fileFormat.sampleRate,
            channels: firstFile.fileFormat.channelCount,
            interleaved: false
        ) else {
            throw RecorderError.exportFailed
        }
        let output = try AVAudioFile(
            forWriting: finalURL,
            settings: fileFormat.settings,
            commonFormat: targetFormat.commonFormat,
            interleaved: targetFormat.isInterleaved
        )
        for segmentURL in segmentURLs {
            try appendAudioFile(at: segmentURL, to: output, targetFormat: targetFormat)
        }
    }

    private static func appendAudioFile(
        at url: URL,
        to output: AVAudioFile,
        targetFormat: AVAudioFormat
    ) throws {
        let input = try AVAudioFile(forReading: url)
        let sourceFormat = input.processingFormat
        let chunkSize: AVAudioFrameCount = 4_096

        while input.framePosition < input.length {
            let remaining = input.length - input.framePosition
            let frameCount = AVAudioFrameCount(min(Int64(chunkSize), remaining))
            guard let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: frameCount
            ) else {
                throw RecorderError.exportFailed
            }
            try input.read(into: sourceBuffer, frameCount: frameCount)
            guard sourceBuffer.frameLength > 0 else { continue }

            if sourceFormat.recappiMatches(targetFormat) {
                try output.write(from: sourceBuffer)
                continue
            }

            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw RecorderError.exportFailed
            }
            let convertedCapacity = AVAudioFrameCount(
                ceil(Double(sourceBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate) + 32
            )
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: max(convertedCapacity, 1)
            ) else {
                throw RecorderError.exportFailed
            }

            let inputState = AudioFileConverterInputState(source: sourceBuffer)
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                inputState.next(status: inputStatus)
            }
            guard conversionError == nil, status != .error else {
                throw RecorderError.exportFailed
            }
            if converted.frameLength > 0 {
                try output.write(from: converted)
            }
        }
    }
}

private final class AudioFileConverterInputState: @unchecked Sendable {
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

private extension AVAudioFormat {
    func recappiMatches(_ other: AVAudioFormat) -> Bool {
        commonFormat == other.commonFormat
            && abs(sampleRate - other.sampleRate) < 0.1
            && channelCount == other.channelCount
            && isInterleaved == other.isInterleaved
    }
}

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
            print("Failed to write audio capture diagnostics: \(error.localizedDescription)")
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
