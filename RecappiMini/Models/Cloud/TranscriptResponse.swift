import Foundation

struct TranscriptResponse: Decodable, Equatable, Sendable {
    let id: String
    let text: String
    let summaryStatus: TranscriptSummaryStatus?
    let summary: String?
    let actionItems: [String]?
    let summaryInsights: TranscriptSummaryInsights?
    let segments: [TranscriptSegment]

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case summaryStatus
        case summary
        case summaryJson
        case summaryInsights
        case actionItems
        case actionItemsJson
        case segments
        case segmentsJson
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)

        let decodedSegments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments)
            ?? Self.decodeSegmentsJSON(try container.decodeIfPresent(String.self, forKey: .segmentsJson))
            ?? []
        segments = Self.normalizeSegmentTimeline(
            decodedSegments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )

        let decodedText = try container.decodeIfPresent(String.self, forKey: .text)
        text = Self.textFromSegments(segments) ?? decodedText ?? ""
        summaryStatus = try container.decodeIfPresent(TranscriptSummaryStatus.self, forKey: .summaryStatus)

        let decodedSummaryInsights = try container.decodeIfPresent(TranscriptSummaryInsights.self, forKey: .summaryInsights)
            ?? Self.decodeSummaryJSON(try container.decodeIfPresent(String.self, forKey: .summaryJson))
        summaryInsights = decodedSummaryInsights?.isEmpty == false ? decodedSummaryInsights : nil
        summary = cleanedTranscriptText(try container.decodeIfPresent(String.self, forKey: .summary))
            ?? summaryInsights?.summaryText

        let directActionItems = try container.decodeIfPresent([String].self, forKey: .actionItems)
            ?? Self.decodeActionItemsJSON(try container.decodeIfPresent(String.self, forKey: .actionItemsJson))
        let normalizedDirectActionItems = directActionItems.map(Self.normalizeActionItems)
        actionItems = Self.nonEmpty(normalizedDirectActionItems) ?? summaryInsights?.actionItemTexts
    }

    private static func decodeSegmentsJSON(_ raw: String?) -> [TranscriptSegment]? {
        guard let raw,
              let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([TranscriptSegment].self, from: data)
    }

    private static func decodeActionItemsJSON(_ raw: String?) -> [String]? {
        guard let raw else { return nil }
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return normalizeActionItems(decoded)
    }

    private static func normalizeActionItems(_ items: [String]) -> [String] {
        items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func decodeSummaryJSON(_ raw: String?) -> TranscriptSummaryInsights? {
        guard let raw,
              let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(TranscriptSummaryInsights.self, from: data)
    }

    private static func nonEmpty(_ values: [String]?) -> [String]? {
        guard let values, !values.isEmpty else { return nil }
        return values
    }

    private static func textFromSegments(_ segments: [TranscriptSegment]) -> String? {
        let lines = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func normalizeSegmentTimeline(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let durations = segments.compactMap { segment -> Int? in
            guard let start = segment.startMs, let end = segment.endMs, end > start else { return nil }
            return end - start
        }
        guard let maxEnd = segments.compactMap(\.endMs).max(),
              let medianDuration = durations.sorted().dropFirst(durations.count / 2).first,
              maxEnd < 24 * 60 * 60,
              medianDuration <= 120 else {
            return segments
        }

        return segments.map { $0.scalingTimeline(by: 1000) }
    }
}

enum TranscriptSummaryStatus: String, Codable, Equatable, Sendable {
    case pending
    case queued
    case running
    case succeeded
    case failed
    case skipped

    var isActive: Bool {
        self == .pending || self == .queued || self == .running
    }
}

struct TranscriptSummaryInsights: Codable, Equatable, Sendable {
    let title: String?
    let tldr: String?
    let summary: String?
    let keyPoints: [String]
    let topics: [String]
    let decisions: [String]
    let actionItems: [TranscriptSummaryActionItem]
    let quotes: [TranscriptSummaryQuote]
    let timeline: [TranscriptSummaryTimelineChapter]

    var isEmpty: Bool {
        title == nil &&
            summaryText == nil &&
            keyPoints.isEmpty &&
            topics.isEmpty &&
            decisions.isEmpty &&
            actionItems.allSatisfy { $0.displayText == nil } &&
            quotes.allSatisfy { $0.displayText == nil } &&
            timeline.isEmpty
    }

    var summaryText: String? {
        Self.firstNonEmpty([tldr, summary])
    }

    var actionItemTexts: [String] {
        actionItems.compactMap(\.displayText)
    }

    var quoteTexts: [String] {
        quotes.compactMap(\.displayText)
    }

    enum CodingKeys: String, CodingKey {
        case tldr
        case title
        case summary
        case keyPoints
        case topics
        case decisions
        case actionItems
        case quotes
        case timeline
    }

    init(
        title: String? = nil,
        tldr: String? = nil,
        summary: String? = nil,
        keyPoints: [String] = [],
        topics: [String] = [],
        decisions: [String] = [],
        actionItems: [TranscriptSummaryActionItem] = [],
        quotes: [TranscriptSummaryQuote] = [],
        timeline: [TranscriptSummaryTimelineChapter] = []
    ) {
        self.title = cleanedTranscriptText(title)
        self.tldr = cleanedTranscriptText(tldr)
        self.summary = cleanedTranscriptText(summary)
        self.keyPoints = Self.normalizeStrings(keyPoints)
        self.topics = Self.normalizeStrings(topics)
        self.decisions = Self.normalizeStrings(decisions)
        self.actionItems = actionItems
        self.quotes = quotes
        self.timeline = timeline.filter(\.isDisplayable)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = cleanedTranscriptText(try container.decodeIfPresent(String.self, forKey: .title))
        tldr = cleanedTranscriptText(try container.decodeIfPresent(String.self, forKey: .tldr))
        summary = cleanedTranscriptText(try container.decodeIfPresent(String.self, forKey: .summary))
        keyPoints = Self.decodeStringList(from: container, forKey: .keyPoints)
        topics = Self.decodeStringList(from: container, forKey: .topics)
        decisions = Self.decodeStringList(from: container, forKey: .decisions)
        actionItems = Self.decodeActionItems(from: container)
        quotes = (try? container.decodeIfPresent([TranscriptSummaryQuote].self, forKey: .quotes)) ?? []
        timeline = ((try? container.decodeIfPresent([TranscriptSummaryTimelineChapter].self, forKey: .timeline)) ?? [])
            .filter(\.isDisplayable)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(tldr, forKey: .tldr)
        try container.encodeIfPresent(summary, forKey: .summary)
        if !keyPoints.isEmpty { try container.encode(keyPoints, forKey: .keyPoints) }
        if !topics.isEmpty { try container.encode(topics, forKey: .topics) }
        if !decisions.isEmpty { try container.encode(decisions, forKey: .decisions) }
        if !actionItems.isEmpty { try container.encode(actionItems, forKey: .actionItems) }
        if !quotes.isEmpty { try container.encode(quotes, forKey: .quotes) }
        if !timeline.isEmpty { try container.encode(timeline, forKey: .timeline) }
    }

    private static func decodeActionItems(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [TranscriptSummaryActionItem] {
        if let items = try? container.decodeIfPresent([TranscriptSummaryActionItem].self, forKey: .actionItems) {
            return items
        }
        if let strings = try? container.decodeIfPresent([String].self, forKey: .actionItems) {
            return strings.map { TranscriptSummaryActionItem(what: $0, who: nil) }
        }
        return []
    }

    private static func decodeStringList(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [String] {
        guard let values = try? container.decodeIfPresent([String].self, forKey: key) else {
            return []
        }
        return normalizeStrings(values)
    }

    private static func normalizeStrings(_ values: [String]) -> [String] {
        values.compactMap { cleanedTranscriptText($0) }
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values.lazy.compactMap { cleanedTranscriptText($0) }.first
    }
}

struct TranscriptSummaryTimelineChapter: Codable, Equatable, Sendable {
    let startMs: Int
    let endMs: Int
    let title: String
    let summary: String

    var isDisplayable: Bool {
        endMs > startMs && !title.isEmpty && !summary.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case startMs
        case endMs
        case start
        case end
        case title
        case summary
    }

    init(startMs: Int, endMs: Int, title: String, summary: String) {
        self.startMs = max(0, startMs)
        self.endMs = max(0, endMs)
        self.title = cleanedTranscriptText(title) ?? ""
        self.summary = cleanedTranscriptText(summary) ?? ""
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startMs = max(0, container.decodeMilliseconds(forKeys: [.startMs, .start]) ?? 0)
        endMs = max(0, container.decodeMilliseconds(forKeys: [.endMs, .end]) ?? 0)
        title = cleanedTranscriptText(try container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        summary = cleanedTranscriptText(try container.decodeIfPresent(String.self, forKey: .summary)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startMs, forKey: .startMs)
        try container.encode(endMs, forKey: .endMs)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
    }

}

struct TranscriptSummaryActionItem: Codable, Equatable, Sendable {
    let what: String
    let who: String?

    var displayText: String? {
        guard !what.isEmpty else { return nil }
        guard let who, !who.isEmpty else { return what }
        return "\(who) — \(what)"
    }

    enum CodingKeys: String, CodingKey {
        case what
        case who
    }

    init(what: String, who: String?) {
        self.what = cleanedTranscriptText(what) ?? ""
        self.who = cleanedTranscriptText(who)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        what = cleanedTranscriptText(try container.decodeIfPresent(String.self, forKey: .what)) ?? ""
        who = cleanedTranscriptText(try container.decodeIfPresent(String.self, forKey: .who))
    }
}

struct TranscriptSummaryQuote: Codable, Equatable, Sendable {
    let speaker: String?
    let text: String

    var displayText: String? {
        guard !text.isEmpty else { return nil }
        if let speaker, !speaker.isEmpty {
            return "\(speaker): \"\(text)\""
        }
        return "\"\(text)\""
    }

    enum CodingKeys: String, CodingKey {
        case speaker
        case text
    }

    init(speaker: String?, text: String) {
        self.speaker = cleanedTranscriptText(speaker)
        self.text = cleanedTranscriptText(text) ?? ""
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speaker = cleanedTranscriptText(try container.decodeIfPresent(String.self, forKey: .speaker))
        text = cleanedTranscriptText(try container.decodeIfPresent(String.self, forKey: .text)) ?? ""
    }
}

struct TranscriptSegment: Decodable, Equatable, Sendable {
    let startMs: Int?
    let endMs: Int?
    let text: String
    let speaker: String?

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case startMs
        case endMs
        case startTimeMs
        case endTimeMs
        case text
        case speaker
        case speakerLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startMs = container.decodeMilliseconds(forKeys: [.startMs, .startTimeMs, .start])
        endMs = container.decodeMilliseconds(forKeys: [.endMs, .endTimeMs, .end])
        text = (try container.decodeIfPresent(String.self, forKey: .text)) ?? ""
        speaker = container.decodeFirstString(forKeys: [.speaker, .speakerLabel])
    }

    private init(startMs: Int?, endMs: Int?, text: String, speaker: String?) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speaker = speaker
    }

    func scalingTimeline(by factor: Int) -> TranscriptSegment {
        TranscriptSegment(
            startMs: startMs.map { $0 * factor },
            endMs: endMs.map { $0 * factor },
            text: text,
            speaker: speaker
        )
    }

}

private func cleanedTranscriptText(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private extension KeyedDecodingContainer {
    func decodeMilliseconds(forKeys keys: [Key]) -> Int? {
        for key in keys {
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return Int(value.rounded())
            }
            if let raw = try? decodeIfPresent(String.self, forKey: key),
               let value = Double(raw) {
                return Int(value.rounded())
            }
        }
        return nil
    }
}

private extension KeyedDecodingContainer where Key == TranscriptSegment.CodingKeys {
    func decodeFirstString(forKeys keys: [Key]) -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}
