import AVFoundation
import Foundation

/// Offline-mixes multiple audio files into a single AAC m4a while preserving
/// a high-quality recording artifact for local storage and Recappi Cloud
/// upload. Runs via AVAudioEngine's manual rendering mode so it completes
/// without playback.
///
/// Why not AVAssetExportSession: AppleM4A preset outputs as many audio
/// tracks as the composition has. We need a single mixed track so downstream
/// downstream processing treats it as one continuous signal.
enum AudioMixer {
    /// Output file settings — 48kHz stereo AAC. This keeps the final
    /// `recording.m4a` at a quality level the backend can downsample itself
    /// when needed, while still staying compact enough for routine storage.
    /// Built on demand so we don't need to wrestle with Swift 6 concurrency
    /// for a mutable-type global.
    private static func outputSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000,
        ]
    }

    /// Mixes `sources` together and writes the result to `destination`.
    /// Missing or unreadable sources are skipped silently so a mic-only or
    /// system-only recording still produces output.
    static func mix(sources: [URL], to destination: URL) async throws {
        let readable = sources.compactMap { url -> AVAudioFile? in
            try? AVAudioFile(forReading: url)
        }
        guard !readable.isEmpty else {
            throw RecorderError.exportFailed
        }

        // Offline rendering must happen off the main actor because
        // renderOffline can block for non-trivial durations on long recordings.
        try await Task.detached(priority: .userInitiated) {
            try runOfflineRender(files: readable, destination: destination)
        }.value
    }

    /// All AVFoundation objects used here are created fresh on the background
    /// task, so the helper doesn't need MainActor isolation.
    private static func runOfflineRender(files: [AVAudioFile], destination: URL) throws {
        let engine = AVAudioEngine()
        let mainMixer = engine.mainMixerNode

        // Render directly at the output file's processing format so
        // AVAudioFile.write doesn't need to convert channel count or sample
        // rate (ExtAudioFileWrite rejects mismatches with -50 / paramErr).
        // AVAudioEngine inserts implicit converters between each source's
        // native format and this render format at the mixer.
        guard let renderFormat = AVAudioFormat(
            standardFormatWithSampleRate: 48000,
            channels: 2
        ) else {
            throw RecorderError.exportFailed
        }

        try engine.enableManualRenderingMode(
            .offline,
            format: renderFormat,
            maximumFrameCount: 4096
        )

        var players: [(AVAudioPlayerNode, AVAudioFile)] = []
        for file in files {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: mainMixer, format: file.processingFormat)
            players.append((player, file))
        }

        let outputFile = try AVAudioFile(forWriting: destination, settings: outputSettings())

        try engine.start()
        for (player, file) in players {
            player.scheduleFile(file, at: nil)
            player.play()
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: 4096) else {
            throw RecorderError.exportFailed
        }

        // Longest source file, rescaled to render frames. Shorter sources just
        // go silent once their buffer drains; mix is the sum of live tracks.
        let maxFrames = players
            .map { (_, file) in
                AVAudioFramePosition(
                    Double(file.length)
                        * renderFormat.sampleRate
                        / file.processingFormat.sampleRate
                )
            }
            .max() ?? 0

        renderLoop: while engine.manualRenderingSampleTime < maxFrames {
            let remaining = maxFrames - engine.manualRenderingSampleTime
            let toRender = min(AVAudioFrameCount(remaining), buffer.frameCapacity)

            let status = try engine.renderOffline(toRender, to: buffer)
            switch status {
            case .success, .insufficientDataFromInputNode:
                if buffer.frameLength > 0 {
                    try outputFile.write(from: buffer)
                } else if status == .insufficientDataFromInputNode {
                    // All players drained early; stop rather than spin.
                    break renderLoop
                }
            case .cannotDoInCurrentContext, .error:
                throw RecorderError.exportFailed
            @unknown default:
                throw RecorderError.exportFailed
            }
        }

        for (player, _) in players { player.stop() }
        engine.stop()
    }
}
