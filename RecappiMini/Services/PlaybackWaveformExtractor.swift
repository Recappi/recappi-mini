import AVFoundation
import Foundation

enum PlaybackWaveformExtractor {
    static let defaultBucketCount = 96
    private static let maxFramesPerBucket: AVAudioFramePosition = 8_192

    static func cachedPeaks(
        from url: URL,
        bucketCount: Int = defaultBucketCount
    ) throws -> [Float] {
        let fingerprint = try fingerprint(for: url)
        let cacheURL = cacheURL(for: url, bucketCount: bucketCount)

        if let cached = try? Data(contentsOf: cacheURL),
           let payload = try? JSONDecoder().decode(CachePayload.self, from: cached),
           payload.fingerprint == fingerprint,
           payload.bucketCount == bucketCount {
            return payload.peaks
        }

        let peaks = try peaks(from: url, bucketCount: bucketCount)
        let payload = CachePayload(bucketCount: bucketCount, fingerprint: fingerprint, peaks: peaks)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return peaks
    }

    static func peaks(
        from url: URL,
        bucketCount: Int = defaultBucketCount
    ) throws -> [Float] {
        let bucketCount = max(bucketCount, 1)
        let file = try AVAudioFile(forReading: url)
        let frameCount = max(file.length, 0)
        guard frameCount > 0 else {
            return Array(repeating: 0, count: bucketCount)
        }

        let format = file.processingFormat
        let channelCount = max(Int(format.channelCount), 1)
        let capacity = AVAudioFrameCount(min(maxFramesPerBucket, max(frameCount, 1)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return Array(repeating: 0, count: bucketCount)
        }

        var rawPeaks = [Float]()
        rawPeaks.reserveCapacity(bucketCount)

        for bucketIndex in 0..<bucketCount {
            let bucketStart = framePosition(for: bucketIndex, total: frameCount, buckets: bucketCount)
            let bucketEnd = max(
                bucketStart + 1,
                framePosition(for: bucketIndex + 1, total: frameCount, buckets: bucketCount)
            )
            let bucketLength = max(bucketEnd - bucketStart, 1)
            let framesToRead = min(bucketLength, maxFramesPerBucket)
            let readStart = bucketStart + max((bucketLength - framesToRead) / 2, 0)

            file.framePosition = min(readStart, frameCount - 1)
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: AVAudioFrameCount(framesToRead))
            rawPeaks.append(peak(in: buffer, channelCount: channelCount))
        }

        return normalize(rawPeaks)
    }

    private static func framePosition(
        for bucketIndex: Int,
        total frameCount: AVAudioFramePosition,
        buckets bucketCount: Int
    ) -> AVAudioFramePosition {
        AVAudioFramePosition(
            (Double(frameCount) * Double(bucketIndex) / Double(max(bucketCount, 1))).rounded(.down)
        )
    }

    private static func peak(in buffer: AVAudioPCMBuffer, channelCount: Int) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        if let channels = buffer.floatChannelData {
            var peak: Float = 0
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in 0..<frameLength {
                    peak = max(peak, abs(samples[frame]))
                }
            }
            return min(peak, 1)
        }

        if let channels = buffer.int16ChannelData {
            var peak: Float = 0
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in 0..<frameLength {
                    peak = max(peak, abs(Float(samples[frame]) / 32_768))
                }
            }
            return min(peak, 1)
        }

        return 0
    }

    private static func normalize(_ peaks: [Float]) -> [Float] {
        guard let maxPeak = peaks.max(), maxPeak > 0.0001 else {
            return peaks.map { _ in 0 }
        }

        return peaks.map { peak in
            guard peak > 0 else { return 0 }
            // Square-root scaling keeps quieter speech visible while retaining
            // the broad amplitude shape of the actual recording.
            return min(1, sqrt(peak / maxPeak))
        }
    }

    private static func cacheURL(for url: URL, bucketCount: Int) -> URL {
        url
            .deletingPathExtension()
            .appendingPathExtension("waveform-\(bucketCount).json")
    }

    private static func fingerprint(for url: URL) throws -> AudioFingerprint {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return AudioFingerprint(
            byteCount: values.fileSize ?? 0,
            modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
    }

    private struct CachePayload: Codable {
        let bucketCount: Int
        let fingerprint: AudioFingerprint
        let peaks: [Float]
    }

    private struct AudioFingerprint: Codable, Equatable {
        let byteCount: Int
        let modifiedAt: TimeInterval
    }
}
