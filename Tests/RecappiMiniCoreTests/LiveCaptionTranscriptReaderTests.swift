import XCTest
@testable import RecappiMini

final class LiveCaptionTranscriptReaderTests: XCTestCase {
    private var tmpRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("recappi-live-caption-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tmpRoot {
            try? FileManager.default.removeItem(at: tmpRoot)
        }
        tmpRoot = nil
        try await super.tearDown()
    }

    func testStructuredEntryEncodesSourceTranslationAndLegacyTextFallback() throws {
        let entry = LiveCaptionEntry(
            sourceText: "hello",
            translationText: "你好",
            isFinal: true,
            startedAtMs: 120,
            endedAtMs: 640
        )

        let data = try JSONEncoder().encode([entry])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let encoded = try XCTUnwrap(object.first)

        XCTAssertEqual(encoded["text"] as? String, "hello\n你好")
        XCTAssertEqual(encoded["sourceText"] as? String, "hello")
        XCTAssertEqual(encoded["translationText"] as? String, "你好")
        XCTAssertEqual(encoded["startedAtMs"] as? Int, 120)
        XCTAssertEqual(encoded["endedAtMs"] as? Int, 640)
    }

    func testStructuredEntriesLoadWithoutLegacyMashedFlag() throws {
        let entries = [
            LiveCaptionEntry(
                sourceText: "source one",
                translationText: "translation one",
                isFinal: true,
                startedAtMs: 0,
                endedAtMs: 1000
            ),
            LiveCaptionEntry(
                sourceText: "source two",
                translationText: nil,
                isFinal: false,
                startedAtMs: 1000,
                endedAtMs: 1600
            ),
        ]
        try write(entries)

        let state = LiveCaptionTranscriptReader.load(from: tmpRoot)
        guard case .loaded(let transcript) = state else {
            return XCTFail("Expected loaded transcript, got \(state)")
        }

        XCTAssertEqual(transcript.lines.map(\.source), ["source one", "source two"])
        XCTAssertEqual(transcript.lines.map(\.translation), ["translation one", nil])
        XCTAssertEqual(transcript.lines.map(\.isFinal), [true, false])
        XCTAssertTrue(transcript.hasTimestamps)
        XCTAssertTrue(transcript.hasTranslation)
        XCTAssertFalse(transcript.isLegacyMashed)
    }

    func testLegacyMashedEntriesSplitBestEffortAndStayFlagged() throws {
        let legacyJSON = """
        [
          {
            "text": "original line\\ntranslated line",
            "isFinal": true,
            "startedAtMs": 10,
            "endedAtMs": 20
          },
          {
            "text": "source only",
            "isFinal": false
          }
        ]
        """
        try legacyJSON.data(using: .utf8)!.write(to: tmpRoot.appendingPathComponent("live-captions.json"))

        let state = LiveCaptionTranscriptReader.load(from: tmpRoot)
        guard case .loaded(let transcript) = state else {
            return XCTFail("Expected loaded transcript, got \(state)")
        }

        XCTAssertEqual(transcript.lines.count, 2)
        XCTAssertEqual(transcript.lines[0].source, "original line")
        XCTAssertEqual(transcript.lines[0].translation, "translated line")
        XCTAssertEqual(transcript.lines[1].source, "source only")
        XCTAssertNil(transcript.lines[1].translation)
        XCTAssertFalse(transcript.hasTimestamps, "Mixed timestamp coverage must not advertise timed export support.")
        XCTAssertTrue(transcript.hasTranslation)
        XCTAssertTrue(transcript.isLegacyMashed)
    }

    func testLoadStatesDistinguishUnavailableEmptyAndFailed() throws {
        XCTAssertEqual(LiveCaptionTranscriptReader.load(from: nil), .unavailable)
        XCTAssertEqual(LiveCaptionTranscriptReader.load(from: tmpRoot), .empty)

        try Data("[]".utf8).write(to: tmpRoot.appendingPathComponent("live-captions.json"))
        XCTAssertEqual(LiveCaptionTranscriptReader.load(from: tmpRoot), .empty)

        try Data("{not-json".utf8).write(to: tmpRoot.appendingPathComponent("live-captions.json"))
        guard case .failed = LiveCaptionTranscriptReader.load(from: tmpRoot) else {
            return XCTFail("Malformed live-captions.json must surface as failed.")
        }
    }

    private func write(_ entries: [LiveCaptionEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: tmpRoot.appendingPathComponent("live-captions.json"))
    }
}
