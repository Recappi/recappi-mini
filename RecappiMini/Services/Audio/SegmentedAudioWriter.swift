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

        let writer = try AVAssetWriter(url: segmentURL, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: format.recommendedBitRate,
        ]
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

        try await exporter.export(to: finalURL, as: .m4a)

        for segmentURL in segmentURLs {
            try? fileManager.removeItem(at: segmentURL)
        }

        return finalURL
    }

    private func makeSegmentURL(index: Int) -> URL {
        let baseName = finalURL.deletingPathExtension().lastPathComponent
        let segmentName = "\(baseName)-segment-\(String(format: "%03d", index)).m4a"
        return finalURL.deletingLastPathComponent().appendingPathComponent(segmentName)
    }
}

struct AudioCaptureDiagnostics: Codable {
    struct FileInfo: Codable {
        let role: String
        let fileName: String
        let exists: Bool
        let sampleRate: Double?
        let channelCount: UInt32?
        let durationSeconds: Double?
        let error: String?

        init(role: String, url: URL) {
            self.role = role
            self.fileName = url.lastPathComponent
            self.exists = FileManager.default.fileExists(atPath: url.path)

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

    static func write(sources: [URL], output: URL?, to sessionDir: URL) {
        let diagnostics = AudioCaptureDiagnostics(
            createdAt: Date(),
            sources: sources.map { FileInfo(role: role(for: $0), url: $0) },
            output: output.map { FileInfo(role: "mixed", url: $0) }
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
