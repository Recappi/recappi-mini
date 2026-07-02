import Foundation
import SwiftUI

/// A citation returned by the "Ask this recording" backend, pointing back at a
/// transcript segment. `segmentId` is preferred for jump-to-segment; the time
/// range is the fallback when the transcript was re-rendered and ids shifted.
struct AskCitation: Identifiable, Equatable {
    let segmentId: String?
    let index: Int?
    let startMs: Int?
    let endMs: Int?
    let label: String?
    let speaker: String?
    let snippet: String?

    /// Stable identity for SwiftUI lists: prefer the segment id, fall back to
    /// the index, then the time range.
    var id: String {
        if let segmentId, !segmentId.isEmpty { return segmentId }
        if let index { return "idx-\(index)" }
        return "ms-\(startMs ?? -1)-\(endMs ?? -1)"
    }

    /// Chip text: the backend `label` if present, otherwise a formatted start
    /// time with the speaker.
    var chipText: String {
        if let label, !label.isEmpty { return label }
        var parts: [String] = []
        if let startMs { parts.append(Self.formatTimecode(startMs)) }
        if let speaker, !speaker.isEmpty { parts.append(speaker) }
        return parts.isEmpty ? "Source" : parts.joined(separator: " · ")
    }

    /// Low-interruption inline label shown next to the sentence it supports.
    var inlineText: String {
        if let startMs { return Self.formatTimecode(startMs) }
        if let label, !label.isEmpty {
            let firstRangePart = label
                .split(whereSeparator: { $0 == "-" || $0 == "–" || $0 == "—" })
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            if let firstRangePart, !firstRangePart.isEmpty {
                return firstRangePart
            }
        }
        if let index { return "#\(index + 1)" }
        return "Source"
    }

    var helpText: String {
        guard let snippet, !snippet.isEmpty else { return chipText }
        return "\(chipText)\n\(snippet)"
    }

    static func formatTimecode(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// One event from the Ask SSE stream. The decoder (RecappiAPIClient+Ask) maps
/// raw `event:`/`data:` frames into these; the view model consumes them so the
/// UI stays decoupled from the wire format. (An `error` frame is surfaced by
/// throwing from the stream rather than as a case here.)
enum AskStreamEvent: Equatable {
    case metadata(segmentCount: Int?)
    case answerDelta(String)
    case citation(AskCitation)
    case done(content: String?, citations: [AskCitation])
}

/// Shared inline-citation rendering helpers for Ask answers. The backend keeps
/// `[[seg-N]]` markers in assistant text so every client can place citations
/// near the sentence they support; this helper strips unknown markers and turns
/// known markers into short custom links.
enum AskInlineAnswer {
    private static let markerPattern = #"\[\[(seg-[^\]]+)\]\]"#
    private static let looseMarkerPattern = #"\s*\[?\[seg-[^\]]+\]\]?"#
    private static let citationURLScheme = "recappi-ask-citation"

    static func hasCitationMarkers(_ text: String) -> Bool {
        text.range(of: markerPattern, options: .regularExpression) != nil
    }

    static func strippedDisplay(_ text: String) -> String {
        text.replacingOccurrences(
            of: looseMarkerPattern,
            with: "",
            options: .regularExpression
        )
    }

    static func attributedString(content: String, citations: [AskCitation]) -> AttributedString {
        guard hasCitationMarkers(content), !citations.isEmpty else {
            return markdownChunk(strippedDisplay(content))
        }

        let citationsBySegmentId = Dictionary(
            citations.compactMap { citation -> (String, AskCitation)? in
                guard let segmentId = citation.segmentId, !segmentId.isEmpty else { return nil }
                return (segmentId, citation)
            },
            uniquingKeysWith: { first, _ in first }
        )

        guard let regex = try? NSRegularExpression(pattern: markerPattern) else {
            return markdownChunk(strippedDisplay(content))
        }

        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        var output = AttributedString()
        var lastIndex = content.startIndex
        var lastVisibleCharacter: Character?

        func appendText(_ text: String) {
            guard !text.isEmpty else { return }
            output += markdownChunk(text)
            if let last = text.last {
                lastVisibleCharacter = last
            }
        }

        func appendCitation(_ citation: AskCitation) {
            let prefix = needsLeadingSpace(after: lastVisibleCharacter) ? " " : ""
            var marker = AttributedString(prefix + citation.inlineText)
            marker.link = citationURL(for: citation)
            marker.font = .system(size: 10, weight: .semibold)
            marker.foregroundColor = DT.appAccent.opacity(0.72)
            output += marker
            lastVisibleCharacter = citation.inlineText.last
        }

        for match in regex.matches(in: content, range: nsRange) {
            guard
                let markerRange = Range(match.range, in: content),
                let segmentRange = Range(match.range(at: 1), in: content)
            else {
                continue
            }

            let textBeforeMarker = String(content[lastIndex..<markerRange.lowerBound])
            let segmentId = String(content[segmentRange])
            if let citation = citationsBySegmentId[segmentId] {
                appendText(textBeforeMarker)
                appendCitation(citation)
            } else {
                appendText(cleanupTextBeforeRemovedMarker(
                    textBeforeMarker,
                    nextCharacter: markerRange.upperBound < content.endIndex
                        ? content[markerRange.upperBound]
                        : nil
                ))
            }
            lastIndex = markerRange.upperBound
        }

        appendText(String(content[lastIndex..<content.endIndex]))
        return output
    }

    static func citationId(from url: URL) -> String? {
        guard url.scheme == citationURLScheme else { return nil }
        let raw = url.host ?? url.pathComponents.dropFirst().first
        return raw?.removingPercentEncoding
    }

    private static func citationURL(for citation: AskCitation) -> URL? {
        let encodedId = citation.id.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? citation.id
        return URL(string: "\(citationURLScheme)://\(encodedId)")
    }

    private static func needsLeadingSpace(after character: Character?) -> Bool {
        guard let character else { return false }
        if character.isWhitespace || character.isNewline { return false }
        return true
    }

    private static func cleanupTextBeforeRemovedMarker(_ text: String, nextCharacter: Character?) -> String {
        guard let nextCharacter, ".。!！?？,，;；:：".contains(nextCharacter) else {
            return text
        }
        var result = text
        while let last = result.last, last == " " || last == "\t" {
            result.removeLast()
        }
        return result
    }

    private static func markdownChunk(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
