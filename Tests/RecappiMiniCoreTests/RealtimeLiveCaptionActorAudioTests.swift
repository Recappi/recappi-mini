import AVFoundation
import CoreMedia
import XCTest
@testable import RecappiMini

/// Phase 3b — audio plumbing on `RealtimeLiveCaptionActor`. Up to now
/// `append(sampleBuffer:)` was a stub. This suite pins:
///
/// 1. Audio submitted before the socket is `.live` is buffered (bounded
///    queue) and flushed in order once the actor transitions to `.live`.
/// 2. When the bounded queue overflows, the OLDEST frames are dropped
///    and a dropped-counter increments. Newest frames win.
/// 3. Audio submitted in `.stopping` / `.stopped` / `.reconnecting` is
///    dropped silently (no socket send, no buffer growth).
/// 4. Order of frames is preserved across `.claiming` → `.live`.
/// 5. The on-the-wire JSON event uses the OpenAI `input_audio_buffer.append`
///    shape with a base64-encoded `audio` field.
///
/// The actor's PCM-from-CMSampleBuffer extraction is exercised by the
/// legacy class's tests today and is structurally unchanged when ported,
/// so the new tests drive the actor through a PCM16-bytes test seam
/// rather than constructing real CMSampleBuffers — cheaper to set up and
/// lets the assertions focus on routing, ordering, and back-pressure.
final class RealtimeLiveCaptionActorAudioTests: XCTestCase {
    func testRealtimeAudioEncoderDownsamplesCommonFloatBufferWithoutConverterFallback() throws {
        let sampleBuffer = try Self.makeInterleavedFloatSampleBuffer(
            sampleRate: 48_000,
            channelCount: 2,
            frames: [
                0.2, 0.4,
                0.6, 0.8,
                -0.2, -0.4,
                -0.6, -0.8,
            ]
        )

        let payload = try XCTUnwrap(RealtimeAudioEncoder.pcm16Data(from: sampleBuffer))
        let samples = payload.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Int16.self))
        }

        XCTAssertEqual(samples, [16_384, -16_384])
    }

    // MARK: - Buffered → flushed on .live

    /// Audio submitted while the actor is still `.claiming` must be
    /// buffered, then flushed in submission order on transition to
    /// `.live`. The legacy class drops pre-live frames; the actor must
    /// preserve them to match the architecture-analysis behaviour.
    func testAudioBufferedDuringClaimingFlushesOnLive() async {
        let connector = MockRealtimeSessionConnector()
        connector.holdClaim = true
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        await actor.start()
        await Task.yield()

        // Sanity: we are mid-claim.
        let mid = await actor.lifecycleSnapshotForTesting()
        switch mid {
        case .claiming:
            break
        default:
            XCTFail("Expected .claiming, got \(mid)")
        }

        // Submit two PCM frames while still claiming.
        let a = Data([0x01, 0x02, 0x03, 0x04])
        let b = Data([0x05, 0x06, 0x07, 0x08])
        await actor.appendPCM16ForTesting(a)
        await actor.appendPCM16ForTesting(b)

        let bufferedBeforeLive = await actor.bufferedAudioCountForTesting()
        XCTAssertEqual(bufferedBeforeLive, 2, "Audio submitted during .claiming must be buffered.")

        // Release the claim so the lifecycle reaches .live; this should
        // flush the buffered frames.
        connector.releaseClaim()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        // Allow the flush task to run.
        try? await Task.sleep(nanoseconds: 50_000_000)

        guard let socket = connector.lastIssuedSocket else {
            XCTFail("Expected an open socket after .live transition.")
            return
        }
        let sent = socket.sentTexts
        XCTAssertEqual(sent.count, 2, "Both buffered frames must flush.")

        let decoded = sent.map(Self.decodeAudioFrame)
        XCTAssertEqual(decoded[0], a, "First sent frame must be the first buffered.")
        XCTAssertEqual(decoded[1], b, "Second sent frame must be the second buffered.")

        let bufferedAfterLive = await actor.bufferedAudioCountForTesting()
        XCTAssertEqual(bufferedAfterLive, 0, "Buffer must be drained after flush.")

        _ = await actor.stop(saveTo: nil)
    }

    // MARK: - Overflow drops oldest

    /// When the bounded queue is full, the oldest frame is dropped and
    /// the dropped-counter increments. Newer frames are retained. This
    /// is the back-pressure policy: a stuck `.claiming` cannot crash the
    /// process by ballooning the queue.
    func testAudioBufferOverflowDropsOldest() async {
        let connector = MockRealtimeSessionConnector()
        connector.holdClaim = true
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            // Audio capacity defaults to 128; tests pass a smaller cap
            // so overflow is reachable quickly.
            configuration: .init(
                reconnectDelays: [1, 2, 5, 10, 30],
                audioBufferCapacity: 4
            )
        )

        await actor.start()
        await Task.yield()

        // Submit 6 frames into a cap-4 buffer. The first 2 must be
        // dropped; the last 4 must remain.
        for i in 0..<6 {
            await actor.appendPCM16ForTesting(Data([UInt8(i)]))
        }

        let bufferedCount = await actor.bufferedAudioCountForTesting()
        let droppedCount = await actor.droppedAudioCountForTesting()
        XCTAssertEqual(bufferedCount, 4, "Buffer must respect the configured cap.")
        XCTAssertEqual(droppedCount, 2, "Overflow drops must increment the counter.")

        // Release and assert that exactly frames [2,3,4,5] flushed.
        connector.releaseClaim()
        await connector.waitForSocketOpened()
        try? await Task.sleep(nanoseconds: 50_000_000)

        guard let socket = connector.lastIssuedSocket else {
            XCTFail("Expected a live socket.")
            return
        }
        let sent = socket.sentTexts.map(Self.decodeAudioFrame)
        XCTAssertEqual(sent, [Data([2]), Data([3]), Data([4]), Data([5])])

        _ = await actor.stop(saveTo: nil)
    }

    // MARK: - Drop in .stopping / .stopped

    /// Audio submitted after `stop()` must not be queued or sent. The
    /// transcriber is winding down; resurrecting it via stray audio is
    /// the resurrected-session bug class.
    func testAudioDroppedAfterStop() async {
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

        _ = await actor.stop(saveTo: nil)
        let snapshot = await actor.lifecycleSnapshotForTesting()
        XCTAssertEqual(snapshot, .stopped)

        let priorSent = connector.lastIssuedSocket?.sentTexts.count ?? 0
        await actor.appendPCM16ForTesting(Data([0xAA, 0xBB]))

        let buffered = await actor.bufferedAudioCountForTesting()
        XCTAssertEqual(
            buffered,
            0,
            "Audio submitted after .stopped must not be buffered."
        )
        XCTAssertEqual(
            connector.lastIssuedSocket?.sentTexts.count ?? 0,
            priorSent,
            "Audio submitted after .stopped must not be sent on the (cancelled) socket."
        )
    }

    // MARK: - Drop during reconnecting

    /// While the lifecycle is `.reconnecting` between a failed claim
    /// and a retry, audio must not accumulate in the buffer. The next
    /// `.live` transition starts with fresh audio only; reusing pre-
    /// reconnect frames would replay a window the server already
    /// considered stalled.
    func testAudioDroppedDuringReconnecting() async {
        let connector = MockRealtimeSessionConnector()
        connector.claimFailures = 1
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription,
            configuration: .init(
                reconnectDelays: [0.5],
                audioBufferCapacity: 16
            )
        )

        await actor.start()
        // First claim fails; lifecycle transitions to .reconnecting.
        await connector.waitForClaimResolved()
        try? await Task.sleep(nanoseconds: 30_000_000)

        let mid = await actor.lifecycleSnapshotForTesting()
        switch mid {
        case .reconnecting:
            break
        default:
            XCTFail("Expected .reconnecting, got \(mid)")
        }

        // Submit audio mid-reconnect.
        await actor.appendPCM16ForTesting(Data([0xCC]))
        let bufferedDuringReconnect = await actor.bufferedAudioCountForTesting()
        XCTAssertEqual(
            bufferedDuringReconnect,
            0,
            "Audio submitted during .reconnecting must be dropped, not buffered."
        )

        // Stop to clean up the still-pending reconnect retry.
        _ = await actor.stop(saveTo: nil)
    }

    // MARK: - Order preserved across transition

    /// Order matters. Frames submitted before `.live` flush in
    /// submission order; frames submitted after `.live` send
    /// immediately and preserve their position relative to the flushed
    /// batch. The test alternates pre/post submissions to pin both
    /// behaviours in one check.
    func testAudioOrderPreservedAcrossClaimingToLive() async {
        let connector = MockRealtimeSessionConnector()
        connector.holdClaim = true
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .transcription
        )

        await actor.start()
        await Task.yield()

        // Three frames pre-live.
        for i in 0..<3 {
            await actor.appendPCM16ForTesting(Data([UInt8(i)]))
        }

        connector.releaseClaim()
        await connector.waitForSocketOpened()
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Two frames post-live.
        for i in 3..<5 {
            await actor.appendPCM16ForTesting(Data([UInt8(i)]))
        }
        try? await Task.sleep(nanoseconds: 30_000_000)

        guard let socket = connector.lastIssuedSocket else {
            XCTFail("Expected a live socket.")
            return
        }
        let received = socket.sentTexts.map(Self.decodeAudioFrame)
        XCTAssertEqual(
            received,
            [Data([0]), Data([1]), Data([2]), Data([3]), Data([4])],
            "Order must be preserved across .claiming → .live."
        )

        _ = await actor.stop(saveTo: nil)
    }

    // MARK: - On-wire event shape

    /// The actor must emit the OpenAI transcription event with a
    /// base64-encoded `audio` field. Translation mode wraps the same
    /// payload under `session.input_audio_buffer.append`; both shapes
    /// are required by the upstream proxy.
    func testAudioFrameSerializedAsOpenAIAppendEvent() async {
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

        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        await actor.appendPCM16ForTesting(payload)
        try? await Task.sleep(nanoseconds: 30_000_000)

        guard let socket = connector.lastIssuedSocket,
              let raw = socket.sentTexts.first,
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            XCTFail("Expected a JSON-encoded event on the socket.")
            return
        }

        XCTAssertEqual(json["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(json["audio"] as? String, payload.base64EncodedString())

        _ = await actor.stop(saveTo: nil)
    }

    /// Translation mode uses the `session.*`-prefixed event the OpenAI
    /// translation endpoint expects. Forgetting this prefix is the
    /// "translation drops audio silently" production bug class.
    func testAudioFrameTranslationModeUsesSessionPrefix() async {
        let connector = MockRealtimeSessionConnector()
        let actor = RealtimeLiveCaptionActor(
            connector: connector,
            language: "en",
            mode: .translation(targetLanguage: "zh")
        )

        await actor.start()
        await connector.waitForClaimResolved()
        await connector.waitForSocketOpened()
        await Task.yield()
        await Task.yield()

        await actor.appendPCM16ForTesting(Data([0x11]))
        try? await Task.sleep(nanoseconds: 30_000_000)

        guard let socket = connector.lastIssuedSocket,
              let raw = socket.sentTexts.first,
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            XCTFail("Expected a JSON-encoded event on the socket.")
            return
        }
        XCTAssertEqual(json["type"] as? String, "session.input_audio_buffer.append")

        _ = await actor.stop(saveTo: nil)
    }

    // MARK: - Helpers

    /// Decode the base64 `audio` field from the on-wire JSON. Each
    /// `sendAudio` event the actor pushes carries the encoded PCM16
    /// payload in this field; tests use this to compare with the
    /// original PCM submitted to the actor.
    private static func decodeAudioFrame(_ raw: String) -> Data {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base64 = json["audio"] as? String,
              let payload = Data(base64Encoded: base64) else {
            return Data()
        }
        return payload
    }

    private static func makeInterleavedFloatSampleBuffer(
        sampleRate: Double,
        channelCount: Int,
        frames: [Float]
    ) throws -> CMSampleBuffer {
        let frameCount = frames.count / channelCount
        var data = Data(count: frames.count * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            let target = rawBuffer.bindMemory(to: Float.self)
            for (index, sample) in frames.enumerated() {
                target[index] = sample
            }
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        XCTAssertEqual(status, kCMBlockBufferNoErr)
        let buffer = try XCTUnwrap(blockBuffer)

        status = data.withUnsafeBytes { rawBuffer in
            CMBlockBufferReplaceDataBytes(
                with: rawBuffer.baseAddress!,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        XCTAssertEqual(status, kCMBlockBufferNoErr)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * channelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * channelCount),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(status, noErr)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: try XCTUnwrap(formatDescription),
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(sampleBuffer)
    }
}
