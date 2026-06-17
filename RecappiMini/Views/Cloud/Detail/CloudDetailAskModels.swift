import Foundation

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
    case done(citations: [AskCitation])
}
