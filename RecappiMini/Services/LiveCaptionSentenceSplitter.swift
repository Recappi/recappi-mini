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

        if mode == .translation, text.contains(where: \.isLiveCaptionCJK) {
            return splitCJK(text)
        }
        return splitSpacedLanguage(text)
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
}
