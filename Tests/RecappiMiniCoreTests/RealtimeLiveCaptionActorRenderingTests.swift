import XCTest
@testable import RecappiMini

/// Phase 3d — ported coverage for the transcript / bilingual rendering
/// behaviors the legacy `BackendRealtimeLiveCaptionTranscriber` tests
/// used to exercise via `handleTranscriptDeltaForTesting` /
/// `handleBilingualSourceDeltaForTesting`. After the legacy class
/// was deleted, the same rendering rules now live on
/// `RealtimeLiveCaptionActor.displaySegments()` / the actor's
/// bilingual builder; these tests pin them through the actor's
/// public-ish receive seam (`ingestReceiveEventJSONForTesting`) so a
/// regression in segment joining, sentence-boundary breaks, or
/// soft-cap splitting fails loudly.
final class RealtimeLiveCaptionActorRenderingTests: XCTestCase {
    // MARK: - Transcription rendering

    /// Repeated deltas for the same `item_id` accumulate into a single
    /// display segment without producing two.
    func testAccumulatesRepeatedSameItemDeltas() async {
        let actor = Self.makeActor(language: "en")
        var snapshot: LiveCaptionSnapshot?
        for delta in ["1", "2", "3", "4", "5"] {
            snapshot = await actor.ingestReceiveEventJSONForTesting(Self.deltaJSON(itemID: "item-a", delta: delta))
        }
        XCTAssertEqual(snapshot?.joinedSourceText, "12345")
        XCTAssertEqual(snapshot?.allSegmentsFinal, false)
    }

    /// A `completed` event replaces the in-flight partial text with
    /// the final transcript for that item.
    func testFinalTranscriptReplacesPartial() async {
        let actor = Self.makeActor(language: "en")
        _ = await actor.ingestReceiveEventJSONForTesting(Self.deltaJSON(itemID: "item-a", delta: "Helo"))
        let final = await actor.ingestReceiveEventJSONForTesting(Self.completionJSON(itemID: "item-a", transcript: "Hello"))
        XCTAssertEqual(final?.joinedSourceText, "Hello")
        XCTAssertEqual(final?.allSegmentsFinal, true)
    }

    /// A late delta arriving after the corresponding item completed
    /// must not append to the now-final segment.
    func testIgnoresLateDeltaAfterCompletion() async {
        let actor = Self.makeActor(language: "en")
        _ = await actor.ingestReceiveEventJSONForTesting(Self.deltaJSON(itemID: "item-a", delta: "Hel"))
        let final = await actor.ingestReceiveEventJSONForTesting(Self.completionJSON(itemID: "item-a", transcript: "Hello"))
        let late = await actor.ingestReceiveEventJSONForTesting(Self.deltaJSON(itemID: "item-a", delta: " world"))

        XCTAssertEqual(final?.joinedSourceText, "Hello")
        XCTAssertNil(late, "Late delta against a completed item must not publish a snapshot.")
    }

    /// A finalized sentence boundary on one item, followed by a fresh
    /// item, must split the timeline into two display segments.
    func testStartsNewDisplaySegmentAfterSentenceBoundary() async {
        let actor = Self.makeActor(language: "en")
        _ = await actor.ingestReceiveEventJSONForTesting(
            Self.completionJSON(itemID: "item-a", transcript: "First sentence.")
        )
        let snapshot = await actor.ingestReceiveEventJSONForTesting(
            Self.completionJSON(itemID: "item-b", transcript: "Second sentence.")
        )
        XCTAssertEqual(snapshot?.segments.count, 2)
        XCTAssertEqual(snapshot?.joinedSourceText, "First sentence.\nSecond sentence.")
    }

    /// Short Chinese items without sentence-ending punctuation should
    /// join naturally into a single display segment — no forced line
    /// break per item.
    func testJoinsShortChineseItemsWithoutForcedLineBreaks() async {
        let actor = Self.makeActor(language: "zh")
        var snapshot: LiveCaptionSnapshot?
        for (index, text) in ["这个", "实时字幕", "应该", "自然换行", "不要每段一行"].enumerated() {
            snapshot = await actor.ingestReceiveEventJSONForTesting(
                Self.completionJSON(itemID: "item-\(index)", transcript: text)
            )
        }
        XCTAssertEqual(snapshot?.joinedSourceText, "这个实时字幕应该自然换行不要每段一行")
    }

    /// A long unpunctuated CJK run (each item under the soft cap on
    /// its own but the running concat past it) must soft-break into
    /// at least two display segments.
    func testSoftBreaksLongUnpunctuatedSegments() async {
        let actor = Self.makeActor(language: "zh")
        var snapshot: LiveCaptionSnapshot?
        for index in 0..<12 {
            snapshot = await actor.ingestReceiveEventJSONForTesting(
                Self.completionJSON(
                    itemID: "item-\(index)",
                    transcript: "这是一段没有标点但是会持续很久的实时字幕内容"
                )
            )
        }
        XCTAssertGreaterThanOrEqual(snapshot?.segments.count ?? 0, 2)
        XCTAssertTrue(snapshot?.joinedSourceText.contains("\n") == true)
    }

    /// Twelve finalized items, each with its own sentence-ending
    /// punctuation, must soft-break into multiple display segments —
    /// the legacy "publish continuous caption history" contract.
    func testPublishesContinuousCaptionHistoryWithSoftBreaks() async {
        let actor = Self.makeActor(language: "en")
        var snapshot: LiveCaptionSnapshot?
        for index in 1...12 {
            snapshot = await actor.ingestReceiveEventJSONForTesting(
                Self.completionJSON(
                    itemID: "item-\(index)",
                    transcript: "Caption history line \(index)"
                )
            )
        }
        let text = snapshot?.joinedSourceText ?? ""
        XCTAssertTrue(text.contains("Caption history line 1"))
        XCTAssertTrue(text.contains("Caption history line 12"))
        XCTAssertTrue(text.contains("\n"))
        XCTAssertGreaterThanOrEqual(snapshot?.segments.count ?? 0, 2)
    }

    // MARK: - Bilingual rendering

    /// Pair source + translation deltas must merge into one bilingual
    /// segment carrying both rows.
    func testBilingualMergesSourceAndTranslation() async {
        let actor = Self.makeActor(language: "en", mode: .translation(targetLanguage: "zh"))
        _ = await actor.ingestReceiveEventJSONForTesting(
            Self.sourceDeltaJSON("Recappi many automation smoke test.")
        )
        let partial = await actor.ingestReceiveEventJSONForTesting(
            Self.translationDeltaJSON("回顾这些 mini 自动化冒烟测试")
        )

        XCTAssertEqual(partial?.segments.count, 1)
        XCTAssertEqual(partial?.segments.first?.sourceText, "Recappi many automation smoke test.")
        XCTAssertEqual(partial?.segments.first?.translatedText, "回顾这些 mini 自动化冒烟测试")
        XCTAssertEqual(partial?.segments.first?.isFinal, false)

        let completed = await actor.ingestReceiveEventJSONForTesting(
            Self.translationDeltaJSON("。")
        )
        XCTAssertEqual(completed?.segments.count, 1)
        XCTAssertEqual(completed?.segments.first?.translatedText, "回顾这些 mini 自动化冒烟测试。")
    }

    /// Translation deltas trailing behind multi-sentence source must
    /// stay in the same in-flight bilingual segment until the
    /// translation catches up.
    func testBilingualWaitsWhenTranslationTrailsSourceSentence() async {
        let actor = Self.makeActor(language: "en", mode: .translation(targetLanguage: "zh"))
        _ = await actor.ingestReceiveEventJSONForTesting(
            Self.sourceDeltaJSON("First complete sentence. Second complete sentence.")
        )
        let trailing = await actor.ingestReceiveEventJSONForTesting(
            Self.translationDeltaJSON("第一句还没结束")
        )
        XCTAssertEqual(trailing?.segments.count, 1)
        XCTAssertEqual(trailing?.segments.first?.isFinal, false)

        let caughtUp = await actor.ingestReceiveEventJSONForTesting(
            Self.translationDeltaJSON("。第二句也结束。")
        )
        XCTAssertEqual(caughtUp?.segments.count, 1)
        XCTAssertEqual(caughtUp?.segments.first?.sourceText, "First complete sentence. Second complete sentence.")
        XCTAssertEqual(caughtUp?.segments.first?.translatedText, "第一句还没结束。第二句也结束。")
    }

    // MARK: - drainEntries shape

    /// `drainEntries()` on a translation-mode actor with both streams
    /// active produces one entry per bilingual segment, joining the
    /// trimmed source + translation with `\n` — matches the legacy
    /// on-disk shape.
    func testDrainEntriesBilingualJoinsRowsWithNewline() async {
        let actor = Self.makeActor(language: "en", mode: .translation(targetLanguage: "zh"))
        _ = await actor.ingestReceiveEventJSONForTesting(Self.sourceDeltaJSON("hello"))
        _ = await actor.ingestReceiveEventJSONForTesting(Self.translationDeltaJSON("你好"))

        let entries = await actor.drainEntriesForTesting()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.text, "hello\n你好")
        XCTAssertEqual(entries.first?.sourceText, "hello")
        XCTAssertEqual(entries.first?.translationText, "你好")
        XCTAssertEqual(entries.first?.isFinal, true)
    }

    /// Transcription-mode `drainEntries()` prefers final items when
    /// any are present, otherwise returns the trailing partial — same
    /// rule the legacy `saveEntries` path enforced.
    func testDrainEntriesTranscriptionPrefersFinals() async {
        let actor = Self.makeActor(language: "en")
        _ = await actor.ingestReceiveEventJSONForTesting(
            Self.completionJSON(itemID: "item-a", transcript: "Hello.")
        )
        _ = await actor.ingestReceiveEventJSONForTesting(
            Self.deltaJSON(itemID: "item-b", delta: "Wor")
        )
        let entries = await actor.drainEntriesForTesting()
        XCTAssertEqual(entries.map(\.text), ["Hello."])
        XCTAssertEqual(entries.map(\.sourceText), ["Hello."])
        XCTAssertEqual(entries.map(\.isFinal), [true])
    }

    /// When no finals exist yet, `drainEntries()` returns the trailing
    /// in-flight partial so a stop mid-utterance still persists what
    /// the user saw.
    func testDrainEntriesTranscriptionTrailsPartialWhenNoFinals() async {
        let actor = Self.makeActor(language: "en")
        _ = await actor.ingestReceiveEventJSONForTesting(
            Self.deltaJSON(itemID: "item-a", delta: "Hel")
        )
        _ = await actor.ingestReceiveEventJSONForTesting(
            Self.deltaJSON(itemID: "item-b", delta: "Wor")
        )
        let entries = await actor.drainEntriesForTesting()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.text, "Wor")
        XCTAssertEqual(entries.first?.isFinal, false)
    }

    // MARK: - Terminal close codes

    /// The actor's static `isTerminalCloseCode` mirrors the legacy
    /// helper so the receive-loop teardown rule for 4000-4009 close
    /// codes survives the move onto the actor.
    func testTerminalCloseCodeRangeMatchesLegacyContract() {
        XCTAssertTrue(RealtimeLiveCaptionActor.isTerminalCloseCode(4000))
        XCTAssertTrue(RealtimeLiveCaptionActor.isTerminalCloseCode(4007))
        XCTAssertTrue(RealtimeLiveCaptionActor.isTerminalCloseCode(4009))
        XCTAssertFalse(RealtimeLiveCaptionActor.isTerminalCloseCode(3999))
        XCTAssertFalse(RealtimeLiveCaptionActor.isTerminalCloseCode(4010))
        XCTAssertFalse(RealtimeLiveCaptionActor.isTerminalCloseCode(1011))
    }

    /// 4000 carries the takeover-specific Chinese message; other
    /// terminal codes fall back to the generic "字幕服务已停止" string
    /// optionally suffixed with the close reason.
    func testTerminalCloseUserMessageMentionsTakeoverForCode4000() {
        let message = RealtimeLiveCaptionActor.terminalCloseUserMessage(
            rawCloseCode: 4000,
            reason: "replaced by newer realtime session".data(using: .utf8)
        )
        XCTAssertTrue(message.contains("接管"), "Got: \(message)")
    }

    func testTerminalCloseUserMessageIncludesReasonTextWhenPresent() {
        let message = RealtimeLiveCaptionActor.terminalCloseUserMessage(
            rawCloseCode: 4005,
            reason: "session retired".data(using: .utf8)
        )
        XCTAssertTrue(message.contains("session retired"), "Got: \(message)")
    }

    // MARK: - Helpers

    private static func makeActor(
        language: String,
        mode: RealtimeLiveCaptionMode = .transcription
    ) -> RealtimeLiveCaptionActor {
        RealtimeLiveCaptionActor(
            connector: AlwaysFailingConnector(),
            language: language,
            mode: mode
        )
    }

    private static func deltaJSON(itemID: String, delta: String) -> String {
        "{\"type\":\"conversation.item.input_audio_transcription.delta\",\"item_id\":\"\(itemID)\",\"delta\":\(Self.jsonString(delta))}"
    }

    private static func completionJSON(itemID: String, transcript: String) -> String {
        "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"item_id\":\"\(itemID)\",\"transcript\":\(Self.jsonString(transcript))}"
    }

    private static func sourceDeltaJSON(_ delta: String) -> String {
        "{\"type\":\"session.input_transcript.delta\",\"delta\":\(Self.jsonString(delta))}"
    }

    private static func translationDeltaJSON(_ delta: String) -> String {
        "{\"type\":\"session.output_transcript.delta\",\"delta\":\(Self.jsonString(delta))}"
    }

    private static func jsonString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        if let data, let text = String(data: data, encoding: .utf8) {
            // `[ "value" ]` → drop the outer brackets to get just the
            // quoted string with proper escaping.
            return String(text.dropFirst().dropLast())
        }
        return "\"\(value)\""
    }
}

// MARK: - Test fixtures

/// Connector that fails its claim immediately. The rendering tests
/// never need a live socket — they call `ingestReceiveEventJSONForTesting`
/// directly on a freshly-constructed actor that has not been started.
private struct AlwaysFailingConnector: RealtimeSessionConnector, @unchecked Sendable {
    func claimSession(
        mode: RealtimeLiveCaptionMode,
        language: String
    ) async throws -> RealtimeSessionClaim {
        throw NSError(domain: "test", code: 0)
    }

    func openSocket(for claim: RealtimeSessionClaim) async throws -> RealtimeSocket {
        throw NSError(domain: "test", code: 0)
    }
}
