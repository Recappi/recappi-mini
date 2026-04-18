import AVFoundation
import Foundation

/// Splits an audio file into time-bounded chunks that downstream
/// transcription backends can handle one at a time. Apple's
/// SFSpeechRecognizer effectively caps recordings at about a minute and
/// remote ASR APIs have their own size limits, so anything longer has to
/// be chunked.
enum AudioChunker {
    struct Chunk: Sendable {
        let url: URL
        let startSeconds: Double
        let durationSeconds: Double
    }

    /// Returns a list of chunks. If `source` is already short enough the
    /// result is a single `Chunk` wrapping the original URL (no copy made).
    static func split(
        source: URL,
        chunkSeconds: Double,
        into workingDir: URL
    ) async throws -> [Chunk] {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        if totalSeconds.isNaN || totalSeconds <= 0 {
            throw ChunkerError.emptyAsset
        }
        if totalSeconds <= chunkSeconds {
            return [Chunk(url: source, startSeconds: 0, durationSeconds: totalSeconds)]
        }

        try? FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)

        var chunks: [Chunk] = []
        var start: Double = 0
        var idx = 0
        while start < totalSeconds {
            let end = min(start + chunkSeconds, totalSeconds)
            let chunkURL = workingDir.appendingPathComponent("chunk-\(idx).m4a")
            try? FileManager.default.removeItem(at: chunkURL)

            guard let export = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                throw ChunkerError.exportInitFailed
            }
            export.outputURL = chunkURL
            export.outputFileType = .m4a
            export.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: end - start, preferredTimescale: 600)
            )
            await export.export()
            guard export.status == .completed else {
                throw export.error ?? ChunkerError.exportFailed
            }

            chunks.append(Chunk(url: chunkURL, startSeconds: start, durationSeconds: end - start))
            start = end
            idx += 1
        }

        return chunks
    }

    /// Removes chunk files produced by `split`. Safe to call with the
    /// original source URL — skipped as a no-op since we don't own it.
    static func cleanup(_ chunks: [Chunk], keepingOriginal original: URL) {
        for chunk in chunks where chunk.url != original {
            try? FileManager.default.removeItem(at: chunk.url)
        }
    }
}

enum ChunkerError: LocalizedError {
    case emptyAsset
    case exportInitFailed
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .emptyAsset: return "Audio file is empty or unreadable"
        case .exportInitFailed: return "Couldn't set up audio export session"
        case .exportFailed: return "Failed to split audio into chunks"
        }
    }
}
