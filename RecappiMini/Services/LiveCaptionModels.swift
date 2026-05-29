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
    let isFinal: Bool
    let startedAtMs: Int?
    let endedAtMs: Int?
}
