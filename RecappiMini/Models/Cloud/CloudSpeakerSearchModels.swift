import Foundation

struct CloudSpeakerDisplayOverride: Codable, Equatable, Sendable {
    let displayName: String
    let emoji: String
    let note: String?
}

struct CloudSpeakerDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let rawName: String
    let displayName: String
    let emoji: String
    let colorIndex: Int
    let note: String?
}

enum CloudSpeakerModel {
    static let emojiChoices = ["🎤", "🎧", "📻", "👤", "💬", "✨"]

    static func speakerID(forRawName rawName: String) -> String {
        let normalized = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = normalized.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(sanitized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "speaker" : collapsed
    }

    static func defaultEmoji(at index: Int) -> String {
        emojiChoices[index % emojiChoices.count]
    }

    static func descriptors(
        for segments: [TranscriptSegment],
        overrides: [String: CloudSpeakerDisplayOverride] = [:]
    ) -> [CloudSpeakerDescriptor] {
        let rawNames = uniqueSpeakerNames(from: segments.compactMap(\.speaker))
        return rawNames.enumerated().map { index, rawName in
            descriptor(forRawName: rawName, index: index, overrides: overrides)
        }
    }

    static func descriptor(
        forRawName rawName: String,
        index: Int,
        overrides: [String: CloudSpeakerDisplayOverride] = [:]
    ) -> CloudSpeakerDescriptor {
        let id = speakerID(forRawName: rawName)
        let override = overrides[id]
        let displayName = cleanCloudText(override?.displayName) ?? rawName
        return CloudSpeakerDescriptor(
            id: id,
            rawName: rawName,
            displayName: displayName,
            emoji: cleanCloudText(override?.emoji) ?? defaultEmoji(at: index),
            colorIndex: index % 6,
            note: cleanCloudText(override?.note)
        )
    }

    static func uniqueSpeakerNames(from names: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in names {
            guard let cleaned = cleanCloudText(name), !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            result.append(cleaned)
        }
        return result
    }
}

enum CloudIndexedSearchSource: String, Codable, Equatable, Sendable {
    case transcript
    case summary
}

struct CloudIndexedSearchResult: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let recordingID: String
    let recordingTitle: String
    let source: CloudIndexedSearchSource
    let sectionBreadcrumb: String
    let marker: String?
    let text: String
    let speakerRawName: String?
    let targetSegmentID: String?
}

struct CloudSearchIndexEntry: Equatable, Sendable {
    let id: String
    let recordingID: String
    let recordingTitle: String
    let source: CloudIndexedSearchSource
    let sectionBreadcrumb: String
    let marker: String?
    let text: String
    let speakerRawName: String?
    let targetSegmentID: String?
}

enum CloudSearchIndexBuilder {
    static func entries(recording: CloudRecording, transcript: TranscriptResponse) -> [CloudSearchIndexEntry] {
        var entries: [CloudSearchIndexEntry] = []
        let recordingTitle = recording.presentationTitle

        for (index, segment) in transcript.segments.enumerated() {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let segmentID = segmentDisplayID(index: index, segment: segment)
            entries.append(
                CloudSearchIndexEntry(
                    id: "\(recording.id)-transcript-\(segmentID)",
                    recordingID: recording.id,
                    recordingTitle: recordingTitle,
                    source: .transcript,
                    sectionBreadcrumb: "Transcript",
                    marker: timeMarker(startMs: segment.startMs, endMs: segment.endMs) ?? "#\(index + 1)",
                    text: text,
                    speakerRawName: segment.speaker,
                    targetSegmentID: segmentID
                )
            )
        }

        for entry in summaryEntries(transcript: transcript) {
            entries.append(
                CloudSearchIndexEntry(
                    id: "\(recording.id)-summary-\(entry.section)-\(stableHash(entry.text))",
                    recordingID: recording.id,
                    recordingTitle: recordingTitle,
                    source: .summary,
                    sectionBreadcrumb: "Notes · \(entry.section)",
                    marker: nil,
                    text: entry.text,
                    speakerRawName: nil,
                    targetSegmentID: nil
                )
            )
        }

        return entries
    }

    static func summaryEntries(transcript: TranscriptResponse) -> [(section: String, text: String)] {
        guard let insights = transcript.summaryInsights else {
            if let summary = cleanCloudText(transcript.summary) {
                return [("Overview", summary)]
            }
            return []
        }

        var entries: [(String, String)] = []
        if let summaryText = insights.summaryText {
            entries.append(("TL;DR", summaryText))
        }
        entries.append(contentsOf: insights.keyPoints.map { ("Key points", $0) })
        entries.append(contentsOf: insights.decisions.map { ("Decisions", $0) })
        entries.append(contentsOf: insights.actionItemTexts.map { ("Action items", $0) })
        entries.append(contentsOf: insights.quoteTexts.map { ("Quotes", $0) })
        return entries
    }

    static func segmentDisplayID(index: Int, segment: TranscriptSegment) -> String {
        "segment-\(index)-\(segment.startMs ?? -1)-\(segment.endMs ?? -1)"
    }

    static func timeMarker(startMs: Int?, endMs: Int?) -> String? {
        switch (startMs, endMs) {
        case (.some(let start), .some(let end)):
            return "\(timecode(start))-\(timecode(end))"
        case (.some(let start), .none):
            return timecode(start)
        case (.none, .some(let end)):
            return timecode(end)
        case (.none, .none):
            return nil
        }
    }

    private static func timecode(_ milliseconds: Int) -> String {
        let total = max(0, milliseconds / 1000)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func stableHash(_ text: String) -> String {
        let value = text.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(value, radix: 16)
    }

}

private func cleanCloudText(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}
