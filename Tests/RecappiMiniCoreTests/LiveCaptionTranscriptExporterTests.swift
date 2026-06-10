import XCTest
@testable import RecappiMini

final class LiveCaptionTranscriptExporterTests: XCTestCase {
    private func line(
        _ id: Int,
        source: String,
        translation: String? = nil,
        startMs: Int? = nil,
        endMs: Int? = nil
    ) -> LiveCaptionTranscriptLine {
        LiveCaptionTranscriptLine(
            id: id,
            startMs: startMs,
            endMs: endMs,
            source: source,
            translation: translation,
            isFinal: true
        )
    }

    private func transcript(
        _ lines: [LiveCaptionTranscriptLine],
        hasTimestamps: Bool = false,
        hasTranslation: Bool = false,
        isLegacyMashed: Bool = false
    ) -> LiveCaptionTranscript {
        LiveCaptionTranscript(
            lines: lines,
            hasTimestamps: hasTimestamps,
            hasTranslation: hasTranslation,
            isLegacyMashed: isLegacyMashed
        )
    }

    func testPlainTextSourceOnlyJoinsByNewline() {
        let t = transcript([line(0, source: "hello"), line(1, source: "world")])
        XCTAssertEqual(LiveCaptionTranscriptExporter.plainText(t), "hello\nworld")
    }

    func testPlainTextBilingualPairsSourceAndTranslationWithBlankLineBetween() {
        let t = transcript(
            [line(0, source: "hello", translation: "你好"),
             line(1, source: "bye", translation: "再见")],
            hasTranslation: true
        )
        XCTAssertEqual(LiveCaptionTranscriptExporter.plainText(t), "hello\n你好\n\nbye\n再见")
    }

    func testPlainTextSkipsBlankAndDeduplicatesIdenticalTranslation() {
        let t = transcript(
            [line(0, source: "hello", translation: "hello"),
             line(1, source: "  ", translation: "world")],
            hasTranslation: true
        )
        // Identical translation collapses to source; blank source falls back to translation.
        XCTAssertEqual(LiveCaptionTranscriptExporter.plainText(t), "hello\n\nworld")
    }

    func testSrtNilWhenNoTimestamps() {
        let t = transcript([line(0, source: "hello")], hasTimestamps: false)
        XCTAssertNil(LiveCaptionTranscriptExporter.srt(t))
        XCTAssertNil(LiveCaptionTranscriptExporter.vtt(t))
    }

    func testSrtFormatsCuesWithCommaMillis() {
        let t = transcript(
            [line(0, source: "hello", startMs: 0, endMs: 1500),
             line(1, source: "world", startMs: 1500, endMs: 3250)],
            hasTimestamps: true
        )
        let srt = LiveCaptionTranscriptExporter.srt(t)
        XCTAssertEqual(
            srt,
            "1\n00:00:00,000 --> 00:00:01,500\nhello\n\n2\n00:00:01,500 --> 00:00:03,250\nworld\n"
        )
    }

    func testVttFormatsHeaderAndDotMillisWithBilingualBody() {
        let t = transcript(
            [line(0, source: "hello", translation: "你好", startMs: 3_661_001, endMs: 3_662_000)],
            hasTimestamps: true,
            hasTranslation: true
        )
        let vtt = LiveCaptionTranscriptExporter.vtt(t)
        XCTAssertEqual(
            vtt,
            "WEBVTT\n\n01:01:01.001 --> 01:01:02.000\nhello\n你好\n"
        )
    }
}
