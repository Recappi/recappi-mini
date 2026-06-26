import AVFoundation
import CoreMedia
import XCTest
@testable import RecappiCaptureCore

final class CaptureSegmentedAudioWriterTests: XCTestCase {
    func testWritesSingleCAFIntermediateSegment() async throws {
        let dir = try Self.makeTemporaryDirectory()
        let url = dir.appendingPathComponent("system.caf")
        let queue = DispatchQueue(label: "CaptureSegmentedAudioWriterTests.single")
        let writer = CaptureSegmentedAudioWriter(finalURL: url, processingQueue: queue)

        writer.append(try Self.makeInterleavedFloatSampleBuffer(
            sampleRate: 48_000,
            channelCount: 2,
            timestamp: .zero,
            frames: Self.sineFrames(sampleRate: 48_000, channelCount: 2)
        ))

        let finalizedURL = try await writer.finishWriting()
        XCTAssertEqual(finalizedURL, url)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000, accuracy: 0.1)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertGreaterThan(file.length, 0)
    }

    func testWritesMultipleCAFIntermediateSegmentsWhenFormatChanges() async throws {
        let dir = try Self.makeTemporaryDirectory()
        let url = dir.appendingPathComponent("mic.caf")
        let queue = DispatchQueue(label: "CaptureSegmentedAudioWriterTests.multiple")
        let writer = CaptureSegmentedAudioWriter(finalURL: url, processingQueue: queue)

        writer.append(try Self.makeInterleavedFloatSampleBuffer(
            sampleRate: 48_000,
            channelCount: 2,
            timestamp: .zero,
            frames: Self.sineFrames(sampleRate: 48_000, channelCount: 2)
        ))
        writer.append(try Self.makeInterleavedFloatSampleBuffer(
            sampleRate: 44_100,
            channelCount: 1,
            timestamp: CMTime(value: 1, timescale: 1),
            frames: Self.sineFrames(sampleRate: 44_100, channelCount: 1)
        ))

        let finalizedURL = try await writer.finishWriting()
        XCTAssertEqual(finalizedURL, url)
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 0)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureSegmentedAudioWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func sineFrames(
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int = 2_048
    ) -> [Float] {
        (0..<frameCount).flatMap { frame -> [Float] in
            let sample = Float(sin((Double(frame) / sampleRate) * 440 * 2 * .pi) * 0.1)
            return Array(repeating: sample, count: channelCount)
        }
    }

    private static func makeInterleavedFloatSampleBuffer(
        sampleRate: Double,
        channelCount: Int,
        timestamp: CMTime,
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
            presentationTimeStamp: timestamp,
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
