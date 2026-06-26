import AVFoundation
import CoreMedia
import XCTest
@testable import RecappiCaptureCore

final class CaptureAudioSampleBufferOutputTests: XCTestCase {
    func testAppendsSamplesAndThrottlesCaptureLevels() async throws {
        let dir = try Self.makeTemporaryDirectory()
        let url = dir.appendingPathComponent("system.caf")
        let queue = DispatchQueue(label: "CaptureAudioSampleBufferOutputTests.writer")
        let writer = CaptureSegmentedAudioWriter(finalURL: url, processingQueue: queue)
        var now: TimeInterval = 10
        var levels: [CaptureLevel] = []
        let output = CaptureAudioSampleBufferOutput(
            writer: writer,
            input: .system,
            startedAtUptime: now,
            levelInterval: 0.25,
            uptime: { now }
        ) { level in
            levels.append(level)
        }
        let buffer = try Self.makeInterleavedFloatSampleBuffer(
            sampleRate: 48_000,
            channelCount: 1,
            timestamp: .zero,
            frames: (0..<2_048).map { index in
                index.isMultiple(of: 2) ? Float(0.5) : Float(-0.5)
            }
        )

        output.append(buffer)
        now += 0.10
        output.append(buffer)
        now += 0.16
        output.append(buffer)

        let finalizedURL = try await output.finishWriting()
        XCTAssertEqual(finalizedURL, url)
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 0)
        XCTAssertEqual(levels.map(\.input), [.system, .system])
        XCTAssertEqual(levels.map(\.atMs), [0, 260])
        XCTAssertEqual(levels[0].rmsDb, -6.0206, accuracy: 0.001)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureAudioSampleBufferOutputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
