import Foundation

/// A single utterance / sentence-sized chunk of caption content. The
/// transcriber emits segments keyed by a stable `id` (e.g. the OpenAI Realtime
/// `item_id`) so consumers can incrementally update one segment at a time
/// without reflowing the whole transcript.
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
        case reconnecting
        case listening
        case unavailable
        case failed
    }

    let phase: Phase
    /// Ordered segments in the visible timeline. Empty when the backend has
    /// nothing to display yet (`.preparing`, `.reconnecting`, `.unavailable`,
    /// `.failed` with no captured caption history, etc).
    let segments: [LiveCaptionSegment]
    /// Convenience: true when every segment in `segments` has `isFinal == true`.
    let allSegmentsFinal: Bool
    let message: String?

    /// Joined `sourceText` of all segments, separated by `\n`. Useful for
    /// accessibility labels, saved-transcript writers, and placeholder checks.
    var joinedSourceText: String {
        segments.map(\.sourceText).joined(separator: "\n")
    }

    static func statusOnly(phase: Phase, message: String?) -> LiveCaptionSnapshot {
        .init(phase: phase, segments: [], allSegmentsFinal: false, message: message)
    }
}

struct LiveCaptionEntry: Codable, Equatable, Sendable {
    let text: String
    let sourceText: String?
    let translationText: String?
    let isFinal: Bool
    let startedAtMs: Int?
    let endedAtMs: Int?

    init(
        text: String,
        isFinal: Bool,
        startedAtMs: Int?,
        endedAtMs: Int?,
        sourceText: String? = nil,
        translationText: String? = nil
    ) {
        self.text = text
        self.sourceText = sourceText
        self.translationText = translationText
        self.isFinal = isFinal
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
    }

    init(
        sourceText: String,
        translationText: String? = nil,
        isFinal: Bool,
        startedAtMs: Int?,
        endedAtMs: Int?
    ) {
        let text = [sourceText, translationText]
            .compactMap { value -> String? in
                let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n")
        self.init(
            text: text,
            isFinal: isFinal,
            startedAtMs: startedAtMs,
            endedAtMs: endedAtMs,
            sourceText: sourceText,
            translationText: translationText
        )
    }
}

struct LiveCaptionTranscriptLine: Equatable, Sendable, Identifiable {
    let id: Int
    let startMs: Int?
    let endMs: Int?
    let source: String
    let translation: String?
    let isFinal: Bool
}

struct LiveCaptionTranscript: Equatable, Sendable {
    let lines: [LiveCaptionTranscriptLine]
    let hasTimestamps: Bool
    let hasTranslation: Bool
    let isLegacyMashed: Bool
}

enum LiveCaptionTranscriptLoadState: Equatable, Sendable {
    case unavailable
    case empty
    case loaded(LiveCaptionTranscript)
    case failed(String)

    var transcript: LiveCaptionTranscript? {
        if case .loaded(let transcript) = self { return transcript }
        return nil
    }
}

enum LiveCaptionTranscriptReader {
    static let fileName = "live-captions.json"

    static func load(
        from sessionDir: URL?,
        fileManager: FileManager = .default
    ) -> LiveCaptionTranscriptLoadState {
        guard let sessionDir else { return .unavailable }
        let fileURL = sessionDir.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }

        do {
            let data = try Data(contentsOf: fileURL)
            let entries = try JSONDecoder().decode([LiveCaptionEntry].self, from: data)
            let transcript = transcript(from: entries)
            return transcript.lines.isEmpty ? .empty : .loaded(transcript)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func transcript(from entries: [LiveCaptionEntry]) -> LiveCaptionTranscript {
        var lines: [LiveCaptionTranscriptLine] = []
        var isLegacyMashed = false

        for entry in entries {
            let parsed = parse(entry)
            guard !parsed.source.isEmpty || parsed.translation?.isEmpty == false else {
                continue
            }
            isLegacyMashed = isLegacyMashed || parsed.isLegacy
            lines.append(
                LiveCaptionTranscriptLine(
                    id: lines.count,
                    startMs: entry.startedAtMs,
                    endMs: entry.endedAtMs,
                    source: parsed.source,
                    translation: parsed.translation,
                    isFinal: entry.isFinal
                )
            )
        }

        return LiveCaptionTranscript(
            lines: lines,
            hasTimestamps: !lines.isEmpty && lines.allSatisfy { $0.startMs != nil && $0.endMs != nil },
            hasTranslation: lines.contains { $0.translation?.isEmpty == false },
            isLegacyMashed: isLegacyMashed
        )
    }

    private static func parse(_ entry: LiveCaptionEntry) -> (source: String, translation: String?, isLegacy: Bool) {
        let source = entry.sourceText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = entry.translationText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if source != nil || translation != nil {
            return (
                source?.isEmpty == false ? source! : fallbackSource(from: entry.text, excluding: translation),
                translation?.isEmpty == false ? translation : nil,
                false
            )
        }

        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ("", nil, true) }
        let rows = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard rows.count > 1 else { return (text, nil, true) }
        return (rows[0], rows.dropFirst().joined(separator: "\n"), true)
    }

    private static func fallbackSource(from text: String, excluding translation: String?) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return "" }
        let trimmedTranslation = translation?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTranslation?.isEmpty == false, trimmedText == trimmedTranslation {
            return ""
        }
        if let trimmedTranslation, trimmedTranslation.isEmpty == false {
            let rows = trimmedText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != trimmedTranslation }
            if !rows.isEmpty { return rows.joined(separator: "\n") }
        }
        return trimmedText
    }
}
