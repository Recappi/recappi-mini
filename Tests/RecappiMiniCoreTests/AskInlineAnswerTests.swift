import XCTest
@testable import RecappiMini

final class AskInlineAnswerTests: XCTestCase {
    func testAttributedStringReplacesKnownSegmentMarkersWithInlineTimeLinks() {
        let citations = [
            AskCitation(
                segmentId: "seg-1",
                index: 0,
                startMs: 6_000,
                endMs: 9_000,
                label: "0:06 - 0:09",
                speaker: "Ada",
                snippet: "Launch is Friday."
            ),
            AskCitation(
                segmentId: "seg-2",
                index: 1,
                startMs: 20_000,
                endMs: 24_000,
                label: "0:20 - 0:24",
                speaker: "Ben",
                snippet: "Design review follows."
            ),
        ]

        let attributed = AskInlineAnswer.attributedString(
            content: "Launch is Friday [[seg-1]]. Review follows [[seg-2]].",
            citations: citations
        )

        XCTAssertEqual(
            String(attributed.characters),
            "Launch is Friday 0:06. Review follows 0:20."
        )
        XCTAssertTrue(attributed.runs.contains { $0.link?.scheme == "recappi-ask-citation" })
    }

    func testStrippedDisplayRemovesDoubleAndSingleSegmentMarkers() {
        XCTAssertEqual(
            AskInlineAnswer.strippedDisplay("Launch is Friday [[seg-18]]. Follow up [seg-21]."),
            "Launch is Friday. Follow up."
        )
    }

    func testUnknownMarkersAreRemovedWhenNoCitationMatches() {
        let citation = AskCitation(
            segmentId: "seg-1",
            index: 0,
            startMs: 6_000,
            endMs: 9_000,
            label: nil,
            speaker: nil,
            snippet: nil
        )

        let attributed = AskInlineAnswer.attributedString(
            content: "Known [[seg-1]]. Unknown [[seg-99]].",
            citations: [citation]
        )

        XCTAssertEqual(String(attributed.characters), "Known 0:06. Unknown.")
    }
}
