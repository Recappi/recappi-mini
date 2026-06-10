import Foundation

/// Pure formatters that turn a `LiveCaptionTranscript` into the text the
/// detail view copies or exports. Kept out of the view so the formatting
/// rules (bilingual layout, timecode shape, the honest "no timestamps →
/// no SRT/VTT" gate) are unit-testable without spinning up SwiftUI.
enum LiveCaptionTranscriptExporter {
    /// Plain text for copy / `.txt` export. Always available.
    ///
    /// Source-only transcripts are one utterance per line. Bilingual
    /// transcripts put the translation on its own line under the source and
    /// separate utterances with a blank line so it stays readable / pasteable
    /// instead of collapsing source and translation together.
    static func plainText(_ transcript: LiveCaptionTranscript) -> String {
        let blocks: [String] = transcript.lines.map { line in
            let source = line.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = line.translation?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let translation, !translation.isEmpty, source != translation {
                return source.isEmpty ? translation : "\(source)\n\(translation)"
            }
            return source.isEmpty ? (translation ?? "") : source
        }
        .filter { !$0.isEmpty }

        let separator = transcript.hasTranslation ? "\n\n" : "\n"
        return blocks.joined(separator: separator)
    }

    /// SubRip (`.srt`). Returns `nil` when the transcript has no real
    /// per-line timing — we never fabricate timecodes (`hasTimestamps`
    /// is only true when every line carries start+end), so an export that
    /// would lie about timing simply isn't offered.
    static func srt(_ transcript: LiveCaptionTranscript) -> String? {
        guard transcript.hasTimestamps else { return nil }
        let cues = transcript.lines.enumerated().compactMap { index, line -> String? in
            guard let start = line.startMs, let end = line.endMs else { return nil }
            let body = cueBody(for: line)
            guard !body.isEmpty else { return nil }
            return "\(index + 1)\n\(srtTimecode(start)) --> \(srtTimecode(end))\n\(body)"
        }
        guard !cues.isEmpty else { return nil }
        return cues.joined(separator: "\n\n") + "\n"
    }

    /// WebVTT (`.vtt`). Same no-fabricated-timing gate as `srt`.
    static func vtt(_ transcript: LiveCaptionTranscript) -> String? {
        guard transcript.hasTimestamps else { return nil }
        let cues = transcript.lines.compactMap { line -> String? in
            guard let start = line.startMs, let end = line.endMs else { return nil }
            let body = cueBody(for: line)
            guard !body.isEmpty else { return nil }
            return "\(vttTimecode(start)) --> \(vttTimecode(end))\n\(body)"
        }
        guard !cues.isEmpty else { return nil }
        return "WEBVTT\n\n" + cues.joined(separator: "\n\n") + "\n"
    }

    private static func cueBody(for line: LiveCaptionTranscriptLine) -> String {
        let source = line.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = line.translation?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let translation, !translation.isEmpty, source != translation {
            return source.isEmpty ? translation : "\(source)\n\(translation)"
        }
        return source.isEmpty ? (translation ?? "") : source
    }

    private static func srtTimecode(_ ms: Int) -> String {
        timecode(ms, millisSeparator: ",")
    }

    private static func vttTimecode(_ ms: Int) -> String {
        timecode(ms, millisSeparator: ".")
    }

    private static func timecode(_ ms: Int, millisSeparator: String) -> String {
        let clamped = max(0, ms)
        let hours = clamped / 3_600_000
        let minutes = (clamped % 3_600_000) / 60_000
        let seconds = (clamped % 60_000) / 1000
        let millis = clamped % 1000
        return String(format: "%02d:%02d:%02d\(millisSeparator)%03d", hours, minutes, seconds, millis)
    }
}
