import XCTest
@testable import RecappiMini

/// Perf-pass equivalence coverage for `RealtimeLiveCaptionActor`.
///
/// Two optimizations landed on the actor:
///
/// 1. `sendAudio(_:on:)` builds the `input_audio_buffer.append` wire
///    frame as a directly-constructed JSON string instead of running
///    `JSONSerialization.data(withJSONObject:)` per audio buffer
///    (~100×/s). Both fields are escaping-free (the event type is one of
///    two fixed ASCII constants; the `audio` value is base64, which only
///    uses `[A-Za-z0-9+/=]`). The frames here prove a server / decoder
///    parsing the new string recovers the SAME `{type, audio}` mapping
///    the old `[String: Any]` dict path produced.
///
/// 2. `displaySegments()` / `computeDrainEntriesSnapshot()` memoize the
///    per-item normalization (`normalizedSegmentText` + the
///    `trimmingCharacters` blank probe) keyed by raw text, so a finalized
///    item isn't re-normalized on every subsequent delta. The published
///    segments and drained entries must stay byte-identical to the
///    un-memoized output for every input — including the cache-HIT path
///    (an item finalizes, then more items arrive and reuse the cached
///    derivation) and the cache-INVALIDATE path (an item's raw text
///    changes, so the cache must recompute and never serve the stale
///    derivation).
///
/// The actor publishes through `ingestReceiveEventJSONForTesting` (the
/// same seam `RealtimeLiveCaptionActorRenderingTests` uses) and drains
/// through `drainEntriesForTesting`, so these assertions exercise the
/// real production walk/merge — only the per-item string derivation
/// changed.
final class RealtimeLiveCaptionPerfEquivalenceTests: XCTestCase {

    // MARK: - (2) Normalization-memo output equivalence

    /// Cache-HIT path. Item A finalizes; then items B and C arrive.
    /// On every later delta the production walk re-derives A's
    /// normalization — now served from the memo. The published segments
    /// and drained entries must match the un-memoized reference exactly.
    func testFinalizedItemThenMoreItemsArrive_segmentsAndEntriesMatchReference() async {
        let actor = Self.makeActor()

        _ = await actor.ingestReceiveEventJSONForTesting(
            Self.completionJSON(itemID: "a", transcript: "First sentence.")
        )
        _ = await actor.ingestReceiveEventJSONForTesting(
            Self.completionJSON(itemID: "b", transcript: "Second sentence.")
        )
        let snapshot = await actor.ingestReceiveEventJSONForTesting(
            Self.completionJSON(itemID: "c", transcript: "Third sentence.")
        )
        let entries = await actor.drainEntriesForTesting()

        // Reference: each finalized sentence ends with `.`, so the
        // production sentence-boundary break opens a new display segment
        // per item. The naive normalization of each transcript is the
        // transcript itself (no internal whitespace runs to collapse).
        XCTAssertEqual(
            snapshot?.segments.map(\.sourceText),
            ["First sentence.", "Second sentence.", "Third sentence."]
        )
        XCTAssertEqual(snapshot?.allSegmentsFinal, true)
        XCTAssertEqual(
            snapshot?.joinedSourceText,
            "First sentence.\nSecond sentence.\nThird sentence."
        )

        // Drain prefers finals when any exist; all three are final.
        XCTAssertEqual(
            entries.map(\.text),
            ["First sentence.", "Second sentence.", "Third sentence."]
        )
        XCTAssertEqual(entries.map(\.isFinal), [true, true, true])

        // Determinism cross-check: a fresh actor (empty cache) driven with
        // the identical sequence must publish + drain byte-identical
        // output. Proves the memo introduces no cache-state-dependent skew.
        let replay = await Self.replaySegmentsAndEntries([
            Self.completionJSON(itemID: "a", transcript: "First sentence."),
            Self.completionJSON(itemID: "b", transcript: "Second sentence."),
            Self.completionJSON(itemID: "c", transcript: "Third sentence."),
        ])
        XCTAssertEqual(replay.segments, snapshot?.segments)
        XCTAssertEqual(replay.entries, entries)
    }

    /// Cache-INVALIDATE path. Item A's raw text changes across events
    /// (`"Hel"` → `"Hello"` partial → `"Hello world."` final). The memo
    /// is keyed on raw text, so each change must recompute. If the cache
    /// ever served the stale `"Hel"` normalization the published text
    /// would lag — assert it always reflects the CURRENT text.
    func testItemTextChanges_cacheRecomputesNeverServesStale() async {
        let actor = Self.makeActor()

        let afterHel = await actor.ingestReceiveEventJSONForTesting(
            Self.deltaJSON(itemID: "a", delta: "Hel")
        )
        XCTAssertEqual(afterHel?.joinedSourceText, "Hel")
        XCTAssertEqual(afterHel?.allSegmentsFinal, false)

        let afterHello = await actor.ingestReceiveEventJSONForTesting(
            Self.deltaJSON(itemID: "a", delta: "lo")
        )
        XCTAssertEqual(afterHello?.joinedSourceText, "Hello")
        XCTAssertEqual(afterHello?.allSegmentsFinal, false)

        let afterFinal = await actor.ingestReceiveEventJSONForTesting(
            Self.completionJSON(itemID: "a", transcript: "Hello world.")
        )
        XCTAssertEqual(afterFinal?.joinedSourceText, "Hello world.")
        XCTAssertEqual(afterFinal?.allSegmentsFinal, true)

        let entries = await actor.drainEntriesForTesting()
        XCTAssertEqual(entries.map(\.text), ["Hello world."])
        XCTAssertEqual(entries.map(\.isFinal), [true])
    }

    /// Whitespace collapse must be byte-identical to the naive
    /// `normalizedSegmentText` (split-on-whitespace + single-space join),
    /// served through the memo. Internal runs collapse to one space and
    /// surrounding whitespace is dropped. The reference is computed naively
    /// in-test from the same raw text the actor saw.
    func testWhitespaceCollapseMatchesNaiveNormalization() async {
        let actor = Self.makeActor()
        let raw = "  multiple   internal\tspaces  and\ntrailing  "

        let snapshot = await actor.ingestReceiveEventJSONForTesting(
            Self.completionJSON(itemID: "a", transcript: raw)
        )

        // Reference: the un-memoized normalization the production helper
        // applies per item.
        let referenceNormalized = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        XCTAssertEqual(snapshot?.segments.count, 1)
        XCTAssertEqual(snapshot?.segments.first?.sourceText, referenceNormalized)
        XCTAssertEqual(referenceNormalized, "multiple internal spaces and trailing")
    }

    /// A whitespace-only item is blank under BOTH derivations: its
    /// normalization is empty (skipped from display) and its
    /// `trimmingCharacters(...).isEmpty` blank probe is true (filtered
    /// from drain entries). The memoized blank probe must match the
    /// un-memoized `trimmingCharacters` reference so the drain output
    /// stays byte-identical. A real final follows so drain has a
    /// non-blank entry to prefer.
    func testWhitespaceOnlyItemFilteredFromDisplayAndDrain() async {
        let actor = Self.makeActor()

        _ = await actor.ingestReceiveEventJSONForTesting(
            Self.completionJSON(itemID: "blank", transcript: "   \n\t ")
        )
        let snapshot = await actor.ingestReceiveEventJSONForTesting(
            Self.completionJSON(itemID: "real", transcript: "Real content.")
        )
        let entries = await actor.drainEntriesForTesting()

        // The blank item collapses to nothing; only the real item shows.
        XCTAssertEqual(snapshot?.segments.map(\.sourceText), ["Real content."])
        // Drain mirrors the same blank filter: only the real, final entry.
        XCTAssertEqual(entries.map(\.text), ["Real content."])
        XCTAssertEqual(entries.map(\.isFinal), [true])

        // Reference: the blank probe the drain path memoizes.
        XCTAssertTrue("   \n\t ".trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse("Real content.".trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Trailing-partial drain (no finals yet). When no item is final the
    /// drain returns only the trailing in-flight partial. Mixing a
    /// cache-hit (an earlier partial whose text is unchanged on later
    /// deltas) must not perturb this. Pins that the memo doesn't alter
    /// the final-preference / trailing-partial selection.
    func testNoFinalsTrailingPartialDrainMatchesReference() async {
        let actor = Self.makeActor()

        _ = await actor.ingestReceiveEventJSONForTesting(
            Self.deltaJSON(itemID: "a", delta: "Hel")
        )
        // `b` is the trailing item; its text changes (cache-invalidate)
        // while `a` stays put (cache-hit) on the second `b` delta.
        _ = await actor.ingestReceiveEventJSONForTesting(
            Self.deltaJSON(itemID: "b", delta: "Wor")
        )
        _ = await actor.ingestReceiveEventJSONForTesting(
            Self.deltaJSON(itemID: "b", delta: "ld")
        )
        let entries = await actor.drainEntriesForTesting()

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.text, "World")
        XCTAssertEqual(entries.first?.isFinal, false)
    }

    // MARK: - (1) Manual-JSON wire equivalence

    /// The manually-built `input_audio_buffer.append` frame must parse to
    /// the SAME `{type, audio}` mapping the old `[String: Any]` +
    /// `JSONSerialization` dict path produced — for BOTH event-type
    /// constants and a realistic base64 payload (which exercises `+`, `/`,
    /// and `=` padding, all valid unescaped in a JSON string).
    func testManualAudioFrameParsesToSameMappingAsDictPath() throws {
        // A payload chosen so its base64 contains `+`, `/`, and `=` —
        // the chars a naive escaper might worry about (none need escaping
        // in JSON, which is exactly why the manual path is sound).
        // `Data([0xFB, 0xFF, 0xBF, 0xFE])` base64-encodes to `+/+//g==`.
        let payload = Data([0xFB, 0xFF, 0xBF, 0xFE])
        let base64 = payload.base64EncodedString()
        XCTAssertTrue(base64.contains("+"), "Want a payload exercising +. Got \(base64)")
        XCTAssertTrue(base64.contains("/"), "Want a payload exercising /. Got \(base64)")
        XCTAssertTrue(base64.hasSuffix("="), "Want a payload exercising = padding. Got \(base64)")

        for eventType in ["input_audio_buffer.append", "session.input_audio_buffer.append"] {
            // OLD path: the dict the actor built before this perf pass.
            let dict: [String: Any] = ["type": eventType, "audio": base64]
            let dictData = try JSONSerialization.data(withJSONObject: dict)
            let dictText = try XCTUnwrap(String(data: dictData, encoding: .utf8))

            // NEW path: the directly-constructed string the actor now sends.
            let manualText = "{\"type\":\"\(eventType)\",\"audio\":\"\(base64)\"}"

            // The wire strings may differ in key order / spacing, but both
            // must decode to the identical {type, audio} mapping — that's
            // the equivalence the proxy / server relies on.
            let dictParsed = try Self.parseTypeAudio(dictText)
            let manualParsed = try Self.parseTypeAudio(manualText)
            XCTAssertEqual(manualParsed.type, dictParsed.type, "type mismatch for \(eventType)")
            XCTAssertEqual(manualParsed.audio, dictParsed.audio, "audio mismatch for \(eventType)")
            XCTAssertEqual(manualParsed.type, eventType)
            XCTAssertEqual(manualParsed.audio, base64)

            // And the recovered base64 must round-trip to the original bytes.
            let recovered = try XCTUnwrap(Data(base64Encoded: manualParsed.audio))
            XCTAssertEqual(recovered, payload)

            // Also assert it decodes via a Codable JSONDecoder (the same
            // family the production receive path uses), not just
            // JSONSerialization.
            let decoded = try JSONDecoder().decode(
                AudioFrameWire.self,
                from: Data(manualText.utf8)
            )
            XCTAssertEqual(decoded.type, eventType)
            XCTAssertEqual(decoded.audio, base64)
        }
    }

    /// End-to-end: drive a real audio frame through the actor's live
    /// socket and assert the frame the socket received still decodes to
    /// the expected `{type, audio}` shape — proving the manual string is
    /// well-formed JSON on the actual send path (not just in isolation).
    func testManualAudioFrameOnLiveSocketDecodes() async throws {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x2B])
        await actor.appendPCM16ForTesting(payload)
        try? await Task.sleep(nanoseconds: 30_000_000)

        let raw = try XCTUnwrap(connector.lastIssuedSocket?.sentTexts.first)
        let parsed = try Self.parseTypeAudio(raw)
        XCTAssertEqual(parsed.type, "input_audio_buffer.append")
        XCTAssertEqual(parsed.audio, payload.base64EncodedString())

        _ = await actor.stop(saveTo: nil)
    }

    // MARK: - Helpers

    private struct AudioFrameWire: Decodable {
        let type: String
        let audio: String
    }

    /// Parse a wire frame into its `{type, audio}` strings via
    /// `JSONSerialization` — the same parse a server applies. Throws if
    /// the frame isn't a JSON object with both string fields, which would
    /// itself be a regression in the manual string.
    private static func parseTypeAudio(_ text: String) throws -> (type: String, audio: String) {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let dict = try XCTUnwrap(object as? [String: Any])
        let type = try XCTUnwrap(dict["type"] as? String)
        let audio = try XCTUnwrap(dict["audio"] as? String)
        return (type, audio)
    }

    /// Replay a sequence of receive-event JSON strings into a fresh actor
    /// and return the final published segments + drained entries. Used for
    /// the determinism cross-check (empty-cache replay must match).
    private static func replaySegmentsAndEntries(
        _ events: [String]
    ) async -> (segments: [LiveCaptionSegment], entries: [LiveCaptionEntry]) {
        let actor = makeActor()
        var lastSnapshot: LiveCaptionSnapshot?
        for event in events {
            if let snapshot = await actor.ingestReceiveEventJSONForTesting(event) {
                lastSnapshot = snapshot
            }
        }
        let entries = await actor.drainEntriesForTesting()
        return (lastSnapshot?.segments ?? [], entries)
    }

    private static func makeActor(
        mode: RealtimeLiveCaptionMode = .transcription
    ) -> RealtimeLiveCaptionActor {
        RealtimeLiveCaptionActor(
            connector: PerfEquivalenceFailingConnector(),
            language: "en",
            mode: mode
        )
    }

    private static func deltaJSON(itemID: String, delta: String) -> String {
        "{\"type\":\"conversation.item.input_audio_transcription.delta\",\"item_id\":\"\(itemID)\",\"delta\":\(jsonString(delta))}"
    }

    private static func completionJSON(itemID: String, transcript: String) -> String {
        "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"item_id\":\"\(itemID)\",\"transcript\":\(jsonString(transcript))}"
    }

    private static func jsonString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        if let data, let text = String(data: data, encoding: .utf8) {
            return String(text.dropFirst().dropLast())
        }
        return "\"\(value)\""
    }
}

/// Connector whose claim fails immediately. The memo-equivalence tests
/// never need a live socket — they drive `ingestReceiveEventJSONForTesting`
/// directly on a freshly-constructed (un-started) actor. Named distinctly
/// from the rendering suite's fixture so SPM's single test module sees no
/// duplicate symbol.
private struct PerfEquivalenceFailingConnector: RealtimeSessionConnector, @unchecked Sendable {
    func claimSession(
        mode: RealtimeLiveCaptionMode,
        language: String
    ) async throws -> RealtimeSessionClaim {
        throw NSError(domain: "perf-equivalence-test", code: 0)
    }

    func openSocket(for claim: RealtimeSessionClaim) async throws -> RealtimeSocket {
        throw NSError(domain: "perf-equivalence-test", code: 0)
    }
}
