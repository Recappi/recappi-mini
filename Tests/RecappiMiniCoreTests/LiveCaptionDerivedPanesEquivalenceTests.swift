import XCTest
@testable import RecappiMini

/// Equivalence coverage for the `LiveCaptionFloatingPanel` perf pass that
/// introduced a reference-type memo (`LiveCaptionDerivedCache`) over the
/// sentence-splitter-derived caption panes.
///
/// The memo is a *pure* cache: on a miss it computes
/// `LiveCaptionFloatingPanel.derivedPanes(for:debugText:)` and stores the
/// result; on a hit it returns the stored value verbatim. So proving the
/// optimization is behavior-preserving reduces to two claims, both pinned
/// here:
///
///   1. `derivedPanes` reproduces the *original inline* computed-property
///      pipeline exactly (the new-path output == the hand-written reference
///      output) — across source-only, bilingual, CJK, multi-sentence, empty,
///      and debug-override fixtures.
///   2. `derivedPanes` is a pure function (same inputs → byte-for-byte equal
///      outputs), so a cache hit can never diverge from recomputing.
///
/// These guard the segment IDs / `isFinal` / `sequence` shape and the
/// normalized stream text the panel renders, so a regression in the memo or
/// in the derivation helpers fails loudly.
final class LiveCaptionDerivedPanesEquivalenceTests: XCTestCase {

    // MARK: - Hand-written reference (the pre-memo inline pipeline)

    /// Faithful copy of the original `LiveCaptionFloatingPanel` computed
    /// properties, kept independent of the production code so it can pin the
    /// new `derivedPanes` against the behavior that shipped before the memo.
    private static func referencePanes(
        for segments: [LiveCaptionSegment],
        debugText: String?
    ) -> LiveCaptionFloatingPanel.DerivedPanes {
        func normalized(_ chunks: [String]) -> String {
            chunks
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }

        func panes(_ text: String, mode: LiveCaptionSentenceSplitter.Mode, idPrefix: String) -> [LiveCaptionSegment] {
            let sentences = LiveCaptionSentenceSplitter.split(text, mode: mode)
            return sentences.enumerated().map { index, sentence in
                LiveCaptionSegment(
                    id: "\(idPrefix)-sentence-\(index)",
                    sourceText: sentence,
                    translatedText: nil,
                    isFinal: index < sentences.count - 1,
                    sequence: index
                )
            }
        }

        // sourceStreamText: debug override else normalized join of sourceText.
        let sourceStreamText: String
        if let debugText, !debugText.isEmpty {
            sourceStreamText = debugText
        } else {
            sourceStreamText = normalized(segments.map(\.sourceText))
        }

        // translationStreamText: normalized join of non-empty trimmed
        // translations — never overridden by debug text.
        let translatedChunks = segments.compactMap { segment -> String? in
            let text = segment.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        let translationStreamText = normalized(translatedChunks)

        return LiveCaptionFloatingPanel.DerivedPanes(
            sourceStreamText: sourceStreamText,
            translationStreamText: translationStreamText,
            sourcePaneSegments: panes(sourceStreamText, mode: .source, idPrefix: "caption"),
            translationPaneSegments: panes(translationStreamText, mode: .translation, idPrefix: "translation")
        )
    }

    // MARK: - Fixtures

    private static func seg(
        _ id: String,
        source: String,
        translated: String? = nil,
        isFinal: Bool = true,
        sequence: Int = 0
    ) -> LiveCaptionSegment {
        LiveCaptionSegment(
            id: id,
            sourceText: source,
            translatedText: translated,
            isFinal: isFinal,
            sequence: sequence
        )
    }

    private static var fixtures: [(name: String, segments: [LiveCaptionSegment], debug: String?)] {
        [
            ("empty", [], nil),
            (
                "source-only-single",
                [seg("a", source: "Listening to the meeting audio right now")],
                nil
            ),
            (
                "source-only-multi-sentence",
                [
                    seg("a", source: "If you have a team, pay attention. It is a very important thing."),
                    seg("b", source: "You should pay them too"),
                ],
                nil
            ),
            (
                "source-with-ragged-whitespace",
                [
                    seg("a", source: "  leading and   inner   spaces  "),
                    seg("b", source: "\n\ttrailing tabs and newlines\n"),
                ],
                nil
            ),
            (
                "bilingual",
                [
                    seg("a", source: "Recappi many automation smoke test.", translated: "回顾这些 mini 自动化冒烟测试。"),
                    seg("b", source: "Second complete sentence.", translated: "第二句也结束。"),
                ],
                nil
            ),
            (
                "bilingual-partial-translation",
                [
                    seg("a", source: "First complete sentence. Second complete sentence.", translated: "第一句还没结束"),
                    seg("b", source: "Tail without translation.", translated: nil),
                ],
                nil
            ),
            (
                "translation-only-cjk-long",
                [
                    seg("a", source: "x", translated: "这是一段没有标点但是会持续很久的实时字幕内容这是一段没有标点但是会持续很久的实时字幕内容"),
                ],
                nil
            ),
            (
                "debug-override-set",
                [seg("a", source: "real source", translated: "real translation")],
                "DEBUG fixture caption. With two sentences."
            ),
            (
                "debug-override-empty-string",
                [seg("a", source: "real source", translated: "real translation")],
                ""
            ),
        ]
    }

    // MARK: - Claim 1: new memoized derivation == original inline pipeline

    func testDerivedPanesMatchReferenceAcrossFixtures() {
        for fixture in Self.fixtures {
            let produced = LiveCaptionFloatingPanel.derivedPanes(
                for: fixture.segments,
                debugText: fixture.debug
            )
            let reference = Self.referencePanes(
                for: fixture.segments,
                debugText: fixture.debug
            )
            XCTAssertEqual(
                produced,
                reference,
                "derivedPanes diverged from the pre-memo reference for fixture \(fixture.name)"
            )
        }
    }

    /// Debug override applies to the source side only; translation always
    /// reflects the real recorder translations (matching the original
    /// `translationStreamText`, which never read the env override).
    func testDebugOverrideAffectsSourceButNotTranslation() {
        let segments = [Self.seg("a", source: "real source text", translated: "真实的翻译文本")]
        let produced = LiveCaptionFloatingPanel.derivedPanes(for: segments, debugText: "OVERRIDDEN")

        XCTAssertEqual(produced.sourceStreamText, "OVERRIDDEN")
        XCTAssertEqual(produced.sourcePaneSegments.first?.sourceText, "OVERRIDDEN")
        XCTAssertEqual(produced.translationStreamText, "真实的翻译文本")
    }

    /// Empty debug string must behave as "no override" — the production
    /// `liveCaptionDebugText` normalizes empty to nil, and the source side
    /// must fall through to the real recorder text.
    func testEmptyDebugStringFallsThroughToRealSource() {
        let segments = [Self.seg("a", source: "real source text")]
        let withEmpty = LiveCaptionFloatingPanel.derivedPanes(for: segments, debugText: "")
        let reference = Self.referencePanes(for: segments, debugText: "")
        XCTAssertEqual(withEmpty, reference)
        XCTAssertEqual(withEmpty.sourceStreamText, "real source text")
    }

    // MARK: - Claim 2: derivation is pure (cache hit == recompute)

    func testDerivedPanesIsPureForRepeatedInputs() {
        for fixture in Self.fixtures {
            let first = LiveCaptionFloatingPanel.derivedPanes(for: fixture.segments, debugText: fixture.debug)
            let second = LiveCaptionFloatingPanel.derivedPanes(for: fixture.segments, debugText: fixture.debug)
            XCTAssertEqual(
                first,
                second,
                "derivedPanes is not pure for fixture \(fixture.name); a cache hit could diverge from a recompute"
            )
        }
    }

    /// Segment IDs / `isFinal` / `sequence` follow the same index-derived
    /// shape the panel relies on for SwiftUI identity and viewport pairing.
    func testPaneSegmentShapeMatchesIndexDerivedContract() {
        let segments = [
            Self.seg("a", source: "First sentence. Second sentence. Third sentence."),
        ]
        let produced = LiveCaptionFloatingPanel.derivedPanes(for: segments, debugText: nil)
        let source = produced.sourcePaneSegments

        XCTAssertEqual(source.count, 3)
        XCTAssertEqual(source.map(\.id), ["caption-sentence-0", "caption-sentence-1", "caption-sentence-2"])
        XCTAssertEqual(source.map(\.sequence), [0, 1, 2])
        // Only the last sentence is non-final (the in-flight tail).
        XCTAssertEqual(source.map(\.isFinal), [true, true, false])
        XCTAssertTrue(source.allSatisfy { $0.translatedText == nil })
    }
}
