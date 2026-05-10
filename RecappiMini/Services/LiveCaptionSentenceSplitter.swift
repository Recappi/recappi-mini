import Foundation

enum LiveCaptionSentenceSplitter {
    enum Mode {
        case source
        case translation
    }

    static func split(_ rawText: String, mode: Mode) -> [String] {
        let text = rawText
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let sentenceSegments = if mode == .translation, text.contains(where: \.isLiveCaptionCJK) {
            splitCJK(text)
        } else {
            splitSpacedLanguage(text)
        }
        return mergeTinyTrailingSegment(
            sentenceSegments.flatMap { splitLongSegment($0, mode: mode) },
            mode: mode
        )
    }

    private static func splitCJK(_ text: String) -> [String] {
        var result: [String] = []
        var sentenceStart = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index].isLiveCaptionCJKSentenceEnd else {
                index = text.index(after: index)
                continue
            }

            var boundaryEnd = text.index(after: index)
            while boundaryEnd < text.endIndex, text[boundaryEnd].isLiveCaptionClosingPunctuation {
                boundaryEnd = text.index(after: boundaryEnd)
            }

            appendSegment(String(text[sentenceStart..<boundaryEnd]), to: &result)
            sentenceStart = skipWhitespace(in: text, from: boundaryEnd)
            index = sentenceStart
        }

        appendSegment(String(text[sentenceStart..<text.endIndex]), to: &result)
        return result
    }

    private static func splitSpacedLanguage(_ text: String) -> [String] {
        var result: [String] = []
        var sentenceStart = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index].isLiveCaptionSpacedSentenceEnd else {
                index = text.index(after: index)
                continue
            }

            var boundaryEnd = text.index(after: index)
            while boundaryEnd < text.endIndex, text[boundaryEnd].isLiveCaptionClosingPunctuation {
                boundaryEnd = text.index(after: boundaryEnd)
            }

            guard shouldSplitSpacedLanguage(text, start: sentenceStart, punctuation: index, boundaryEnd: boundaryEnd) else {
                index = boundaryEnd
                continue
            }

            appendSegment(String(text[sentenceStart..<boundaryEnd]), to: &result)
            sentenceStart = skipWhitespace(in: text, from: boundaryEnd)
            index = sentenceStart
        }

        appendSegment(String(text[sentenceStart..<text.endIndex]), to: &result)
        return result
    }

    private static func shouldSplitSpacedLanguage(
        _ text: String,
        start: String.Index,
        punctuation: String.Index,
        boundaryEnd: String.Index
    ) -> Bool {
        let afterBoundary = boundaryEnd < text.endIndex ? text[boundaryEnd] : nil
        guard afterBoundary == nil || afterBoundary?.isWhitespace == true else {
            return false
        }

        if text[punctuation] == "." {
            let previous = punctuation > text.startIndex ? text[text.index(before: punctuation)] : nil
            let next = boundaryEnd < text.endIndex ? text[boundaryEnd] : nil
            if previous?.isNumber == true, next?.isNumber == true {
                return false
            }

            let token = tokenBeforePeriod(in: text, punctuation: punctuation)
            if Self.commonAbbreviations.contains(token.lowercased()) {
                return false
            }
        }

        let segment = text[start...punctuation]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return segment.count >= 6
    }

    private static func tokenBeforePeriod(in text: String, punctuation: String.Index) -> String {
        var start = punctuation
        while start > text.startIndex {
            let candidate = text.index(before: start)
            let character = text[candidate]
            guard character.isLetter || character == "." else { break }
            start = candidate
        }
        return String(text[start..<punctuation])
    }

    private static func appendSegment(_ rawSegment: String, to result: inout [String]) {
        let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return }
        result.append(segment)
    }

    private static func splitLongSegment(_ segment: String, mode: Mode) -> [String] {
        var remaining = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remaining.isEmpty else { return [] }

        let limit = longSegmentLimit(for: remaining, mode: mode)
        guard remaining.count > limit else { return [remaining] }

        var result: [String] = []
        while remaining.count > limit {
            let cutIndex = preferredSoftCutIndex(in: remaining, limit: limit, mode: mode)
            appendSegment(String(remaining[..<cutIndex]), to: &result)
            remaining = String(remaining[cutIndex...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        appendSegment(remaining, to: &result)
        return result
    }

    private static func longSegmentLimit(for text: String, mode: Mode) -> Int {
        if mode == .translation, text.contains(where: \.isLiveCaptionCJK) {
            return 42
        }
        return 90
    }

    private static func mergeTinyTrailingSegment(_ segments: [String], mode: Mode) -> [String] {
        guard segments.count > 1, let tail = segments.last else { return segments }

        let limit = tinyTrailingSegmentLimit(for: tail, mode: mode)
        guard tail.count < limit else { return segments }

        var result = Array(segments.dropLast())
        guard let previous = result.popLast() else { return segments }
        let separator = shouldJoinWithoutSpace(previous: previous, tail: tail, mode: mode) ? "" : " "
        result.append(previous + separator + tail)
        return result
    }

    private static func tinyTrailingSegmentLimit(for text: String, mode: Mode) -> Int {
        if mode == .translation, text.contains(where: \.isLiveCaptionCJK) {
            return 8
        }
        return 12
    }

    private static func shouldJoinWithoutSpace(previous: String, tail: String, mode: Mode) -> Bool {
        mode == .translation && (previous.contains(where: \.isLiveCaptionCJK) || tail.contains(where: \.isLiveCaptionCJK))
    }

    private static func preferredSoftCutIndex(
        in text: String,
        limit: Int,
        mode: Mode
    ) -> String.Index {
        let end = text.index(text.startIndex, offsetBy: min(limit, text.count))
        let minimumPrefix = text.index(text.startIndex, offsetBy: min(max(limit / 2, 24), text.count))
        let searchRange = minimumPrefix..<end

        if let punctuation = text[searchRange]
            .indices
            .reversed()
            .first(where: { text[$0].isLiveCaptionSoftBoundary(for: mode) }) {
            return text.index(after: punctuation)
        }

        if let whitespace = text[searchRange]
            .indices
            .reversed()
            .first(where: { text[$0].isWhitespace }) {
            return whitespace
        }

        return end
    }

    private static func skipWhitespace(in text: String, from index: String.Index) -> String.Index {
        var current = index
        while current < text.endIndex, text[current].isWhitespace {
            current = text.index(after: current)
        }
        return current
    }

    private static let commonAbbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc",
        "e.g", "i.e", "u.s", "u.k",
    ]
}

private extension Character {
    var isLiveCaptionCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x3040...0x30FF).contains(scalar.value) ||
                (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    var isLiveCaptionCJKSentenceEnd: Bool {
        self == "。" || self == "！" || self == "？"
    }

    var isLiveCaptionSpacedSentenceEnd: Bool {
        self == "." || self == "!" || self == "?"
    }

    var isLiveCaptionClosingPunctuation: Bool {
        self == "\"" || self == "'" || self == "”" || self == "’" ||
            self == "」" || self == "』" || self == ")" || self == "）" ||
            self == "]" || self == "】"
    }

    func isLiveCaptionSoftBoundary(for mode: LiveCaptionSentenceSplitter.Mode) -> Bool {
        switch mode {
        case .source:
            return self == "," || self == ";" || self == ":" ||
                self == "—" || self == "–"
        case .translation:
            return self == "，" || self == "," || self == "；" ||
                self == ";" || self == "、" || self == "："
        }
    }
}
