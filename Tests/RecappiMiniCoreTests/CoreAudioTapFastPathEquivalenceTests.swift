import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import XCTest
@testable import RecappiMini

/// Proves the `CoreAudioTapSampleBufferFactory` perf rewrite (Option A direct
/// fast path + reused scratch + vDSP int16 conversion) emits byte-identical PCM,
/// frame counts, and timing versus the original allocate-and-scalar-copy code.
///
/// The reference functions below reproduce the *old* `interleavedFloat32Samples`
/// element-for-element; each test feeds an `AudioBufferList` through the real
/// factory and asserts the produced CMSampleBuffer matches the reference bytes.
final class CoreAudioTapFastPathEquivalenceTests: XCTestCase {
    private let sampleRate: Double = 48_000

    // MARK: - Fast path (Option A): single packed interleaved float32, matching channels

    func testFastPathStereoFloat32IsByteIdentical() throws {
        let frames = 512
        let interleaved = makeInterleavedFloat32(frames: frames, channels: 2, seed: 1)
        try assertEquivalent(sourceChannels: 2, floatSamples: interleaved, int16Samples: nil)
    }

    func testFastPathMonoFloat32IsByteIdentical() throws {
        let frames = 333
        let interleaved = makeInterleavedFloat32(frames: frames, channels: 1, seed: 7)
        try assertEquivalent(sourceChannels: 1, floatSamples: interleaved, int16Samples: nil)
    }

    /// Partial trailing frame: byte length must drop the remainder exactly like
    /// the old `frames = availableSamples / sourceChannels` truncation.
    func testFastPathStereoFloat32WithPartialFrameTruncatesIdentically() throws {
        // 2 channels, 100 frames + 1 dangling sample (odd float count).
        var interleaved = makeInterleavedFloat32(frames: 100, channels: 2, seed: 3)
        interleaved.append(0.4242)
        try assertEquivalent(sourceChannels: 2, floatSamples: interleaved, int16Samples: nil)
    }

    // MARK: - Conversion path: >2ch float32 source downmixed to stereo (channel clamp)

    /// 6-channel interleaved float32. The factory clamps output to 2 channels, so
    /// this misses the fast path and takes the single-buffer remap branch with
    /// `min(channel, sourceChannels - 1)` selecting channels 0 and 1.
    func testSingleBufferFloat32SixChannelDownmixRemap() throws {
        let interleaved = makeInterleavedFloat32(frames: 256, channels: 6, seed: 11)
        try assertEquivalent(sourceChannels: 6, floatSamples: interleaved, int16Samples: nil)
    }

    // MARK: - Conversion path: int16 single interleaved buffer (scalar remap)

    func testSingleBufferInt16StereoIsByteIdentical() throws {
        let interleaved = makeInterleavedInt16(frames: 480, channels: 2, seed: 17)
        try assertEquivalent(sourceChannels: 2, floatSamples: nil, int16Samples: interleaved)
    }

    func testSingleBufferInt16MonoIsByteIdentical() throws {
        let interleaved = makeInterleavedInt16(frames: 480, channels: 1, seed: 19)
        try assertEquivalent(sourceChannels: 1, floatSamples: nil, int16Samples: interleaved)
    }

    func testSingleBufferInt16SixChannelDownmixRemap() throws {
        let interleaved = makeInterleavedInt16(frames: 256, channels: 6, seed: 23)
        try assertEquivalent(sourceChannels: 6, floatSamples: nil, int16Samples: interleaved)
    }

    // MARK: - Scratch reuse: two calls of different sizes through the same factory

    func testScratchReuseAcrossDifferentSizedBuffersStaysCorrect() throws {
        // 6-channel source so each call routes through the scratch-filling remap
        // (not the fast path) and reuses the same scratch storage.
        let factory = try CoreAudioTapSampleBufferFactory(sourceFormat: asbd(channels: 6, isFloat: false, bits: 16))

        let large = makeInterleavedInt16(frames: 800, channels: 6, seed: 31)
        let small = makeInterleavedInt16(frames: 64, channels: 6, seed: 37)

        // First a large buffer, then a small one: the small call must read only
        // its own prefix, never the stale large tail.
        try runInt16(factory: factory, samples: large, sourceChannels: 6)
        try runInt16(factory: factory, samples: small, sourceChannels: 6)
    }

    // MARK: - Conversion path: non-interleaved (planar) multi-buffer sources

    /// Two planar float32 buffers, stereo output: exercises the per-channel
    /// scatter (the `outputChannels > 1` branch of the float32 multi path).
    func testPlanarFloat32StereoScatterIsByteIdentical() throws {
        let frames = 400
        let left = makePlanarFloat32(frames: frames, seed: 41)
        let right = makePlanarFloat32(frames: frames, seed: 43)
        try assertPlanarFloat32Equivalent(planes: [left, right], outputChannels: 2)
    }

    /// Single planar float32 plane folded to mono output: exercises the
    /// contiguous `memcpy` fast copy in the multi/planar branch.
    func testPlanarFloat32MonoMemcpyIsByteIdentical() throws {
        let frames = 300
        let plane = makePlanarFloat32(frames: frames, seed: 47)
        try assertPlanarFloat32Equivalent(planes: [plane], outputChannels: 1, sourceIsNonInterleaved: true)
    }

    /// Single planar int16 plane folded to mono: exercises the vDSP
    /// `convertInt16ToFloat` contiguous path.
    func testPlanarInt16MonoVDSPIsByteIdentical() throws {
        let frames = 256
        let plane = makePlanarInt16(frames: frames, seed: 53)
        try assertPlanarInt16Equivalent(planes: [plane], outputChannels: 1, sourceIsNonInterleaved: true)
    }

    /// Two planar int16 buffers, stereo output: exercises the int16 per-channel
    /// scatter branch.
    func testPlanarInt16StereoScatterIsByteIdentical() throws {
        let frames = 256
        let left = makePlanarInt16(frames: frames, seed: 59)
        let right = makePlanarInt16(frames: frames, seed: 61)
        try assertPlanarInt16Equivalent(planes: [left, right], outputChannels: 2)
    }

    // MARK: - Equivalence driver

    /// The factory clamps its output channel count to `min(max(src, 1), 2)`
    /// (see `CoreAudioTapSampleBufferFactory.init`). Tests must compare against a
    /// reference built with the SAME output channel count, so derive it here.
    private func expectedOutputChannels(sourceChannels: Int) -> Int {
        min(max(sourceChannels, 1), 2)
    }

    private func assertEquivalent(
        sourceChannels: Int,
        floatSamples: [Float]?,
        int16Samples: [Int16]?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let outputChannels = expectedOutputChannels(sourceChannels: sourceChannels)
        let isFloat = floatSamples != nil
        let factory = try CoreAudioTapSampleBufferFactory(
            sourceFormat: asbd(channels: sourceChannels, isFloat: isFloat, bits: isFloat ? 32 : 16)
        )

        let expected: [Float]
        let producedBytes: [UInt8]
        let producedFrameCount: Int

        if let floatSamples {
            expected = referenceFloat32(
                source: floatSamples,
                sourceChannels: sourceChannels,
                outputChannels: outputChannels
            )
            (producedBytes, producedFrameCount) = try produceFloat32(
                factory: factory,
                samples: floatSamples,
                sourceChannels: sourceChannels
            )
        } else if let int16Samples {
            expected = referenceInt16(
                source: int16Samples,
                sourceChannels: sourceChannels,
                outputChannels: outputChannels
            )
            (producedBytes, producedFrameCount) = try produceInt16(
                factory: factory,
                samples: int16Samples,
                sourceChannels: sourceChannels
            )
        } else {
            XCTFail("no samples provided", file: file, line: line)
            return
        }

        XCTAssertEqual(producedFrameCount, expected.count / outputChannels, file: file, line: line)
        let expectedBytes = floatArrayToBytes(expected)
        XCTAssertEqual(producedBytes, expectedBytes, "PCM bytes diverged from reference", file: file, line: line)
    }

    // MARK: - Real factory drivers (build AudioBufferList, run, read bytes)

    private func produceFloat32(
        factory: CoreAudioTapSampleBufferFactory,
        samples: [Float],
        sourceChannels: Int
    ) throws -> (bytes: [UInt8], frameCount: Int) {
        var mutable = samples
        return try mutable.withUnsafeMutableBytes { raw -> ([UInt8], Int) in
            var list = AudioBufferList()
            list.mNumberBuffers = 1
            list.mBuffers = AudioBuffer(
                mNumberChannels: UInt32(sourceChannels),
                mDataByteSize: UInt32(raw.count),
                mData: raw.baseAddress
            )
            return try runList(factory: factory, list: &list)
        }
    }

    private func produceInt16(
        factory: CoreAudioTapSampleBufferFactory,
        samples: [Int16],
        sourceChannels: Int
    ) throws -> (bytes: [UInt8], frameCount: Int) {
        var mutable = samples
        return try mutable.withUnsafeMutableBytes { raw -> ([UInt8], Int) in
            var list = AudioBufferList()
            list.mNumberBuffers = 1
            list.mBuffers = AudioBuffer(
                mNumberChannels: UInt32(sourceChannels),
                mDataByteSize: UInt32(raw.count),
                mData: raw.baseAddress
            )
            return try runList(factory: factory, list: &list)
        }
    }

    private func runInt16(
        factory: CoreAudioTapSampleBufferFactory,
        samples: [Int16],
        sourceChannels: Int
    ) throws {
        let outputChannels = expectedOutputChannels(sourceChannels: sourceChannels)
        let expected = referenceInt16(source: samples, sourceChannels: sourceChannels, outputChannels: outputChannels)
        let (bytes, frameCount) = try produceInt16(
            factory: factory,
            samples: samples,
            sourceChannels: sourceChannels
        )
        XCTAssertEqual(frameCount, expected.count / outputChannels)
        XCTAssertEqual(bytes, floatArrayToBytes(expected))
    }

    private func runList(
        factory: CoreAudioTapSampleBufferFactory,
        list: inout AudioBufferList
    ) throws -> (bytes: [UInt8], frameCount: Int) {
        try withUnsafePointer(to: &list) { ptr in
            try runListPointer(factory: factory, list: ptr)
        }
    }

    /// Runs the factory against the actual (possibly malloc'd, multi-buffer)
    /// `AudioBufferList` storage. Must be used for multi-buffer lists so the
    /// trailing buffers past the inline `mBuffers` head are not copied away.
    private func runListPointer(
        factory: CoreAudioTapSampleBufferFactory,
        list: UnsafePointer<AudioBufferList>
    ) throws -> (bytes: [UInt8], frameCount: Int) {
        let buffer = try factory.makeSampleBuffer(from: list, inputTime: nil)
        let sampleBuffer = try XCTUnwrap(buffer)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let bytes = try copyPCMBytes(sampleBuffer)
        return (bytes, frameCount)
    }

    private func copyPCMBytes(_ sampleBuffer: CMSampleBuffer) throws -> [UInt8] {
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sampleBuffer))
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        let status = bytes.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        XCTAssertEqual(status, kCMBlockBufferNoErr)
        return bytes
    }

    // MARK: - Reference implementations (verbatim copies of the OLD math)

    private func referenceFloat32(source: [Float], sourceChannels: Int, outputChannels: Int) -> [Float] {
        let availableSamples = source.count
        let frames = availableSamples / sourceChannels
        guard frames > 0 else { return [] }
        var out = [Float](repeating: 0, count: frames * outputChannels)
        for frame in 0..<frames {
            for channel in 0..<outputChannels {
                out[frame * outputChannels + channel] = source[frame * sourceChannels + min(channel, sourceChannels - 1)]
            }
        }
        return out
    }

    private func referenceInt16(source: [Int16], sourceChannels: Int, outputChannels: Int) -> [Float] {
        let availableSamples = source.count
        let frames = availableSamples / sourceChannels
        guard frames > 0 else { return [] }
        var out = [Float](repeating: 0, count: frames * outputChannels)
        for frame in 0..<frames {
            for channel in 0..<outputChannels {
                out[frame * outputChannels + channel] =
                    Float(source[frame * sourceChannels + min(channel, sourceChannels - 1)]) / 32768.0
            }
        }
        return out
    }

    // MARK: - Planar (non-interleaved / multi-buffer) drivers + reference

    /// Reference for the OLD planar path: for each output channel read plane
    /// `min(channel, planes.count - 1)` and write into the interleaved layout.
    /// `frameCount` is the minimum plane length (matches `minimumFrameCount`).
    private func referencePlanarFloat32(planes: [[Float]], outputChannels: Int) -> [Float] {
        let frameCount = planes.map(\.count).min() ?? 0
        guard frameCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: frameCount * outputChannels)
        for channel in 0..<outputChannels {
            let plane = planes[min(channel, planes.count - 1)]
            for frame in 0..<frameCount {
                out[frame * outputChannels + channel] = plane[frame]
            }
        }
        return out
    }

    private func referencePlanarInt16(planes: [[Int16]], outputChannels: Int) -> [Float] {
        let frameCount = planes.map(\.count).min() ?? 0
        guard frameCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: frameCount * outputChannels)
        for channel in 0..<outputChannels {
            let plane = planes[min(channel, planes.count - 1)]
            for frame in 0..<frameCount {
                out[frame * outputChannels + channel] = Float(plane[frame]) / 32768.0
            }
        }
        return out
    }

    private func assertPlanarFloat32Equivalent(
        planes: [[Float]],
        outputChannels: Int,
        sourceIsNonInterleaved: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let factory = try CoreAudioTapSampleBufferFactory(
            sourceFormat: planarASBD(
                channels: outputChannels,
                isFloat: true,
                bits: 32,
                nonInterleaved: planes.count == 1 ? sourceIsNonInterleaved : true
            )
        )
        let expected = referencePlanarFloat32(planes: planes, outputChannels: outputChannels)
        let (bytes, frameCount) = try withPlaneList(planes) { listPtr in
            try runListPointer(factory: factory, list: listPtr)
        }
        XCTAssertEqual(frameCount, expected.count / outputChannels, file: file, line: line)
        XCTAssertEqual(bytes, floatArrayToBytes(expected), "planar float32 PCM diverged", file: file, line: line)
    }

    private func assertPlanarInt16Equivalent(
        planes: [[Int16]],
        outputChannels: Int,
        sourceIsNonInterleaved: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let factory = try CoreAudioTapSampleBufferFactory(
            sourceFormat: planarASBD(
                channels: outputChannels,
                isFloat: false,
                bits: 16,
                nonInterleaved: planes.count == 1 ? sourceIsNonInterleaved : true
            )
        )
        let expected = referencePlanarInt16(planes: planes, outputChannels: outputChannels)
        let (bytes, frameCount) = try withPlaneList(planes) { listPtr in
            try runListPointer(factory: factory, list: listPtr)
        }
        XCTAssertEqual(frameCount, expected.count / outputChannels, file: file, line: line)
        XCTAssertEqual(bytes, floatArrayToBytes(expected), "planar int16 PCM diverged", file: file, line: line)
    }

    /// Allocates an `AudioBufferList` with one buffer per plane (each plane is a
    /// mono, contiguous source buffer) and runs `body` against the real malloc'd
    /// list pointer. Each plane is copied into its own stable heap allocation so
    /// every buffer pointer stays valid for the whole call (and so we never hold
    /// overlapping exclusive access to the `planes` array).
    private func withPlaneList<E>(
        _ planes: [[E]],
        _ body: (UnsafePointer<AudioBufferList>) throws -> (bytes: [UInt8], frameCount: Int)
    ) throws -> (bytes: [UInt8], frameCount: Int) {
        let count = planes.count
        let listPtr = AudioBufferList.allocate(maximumBuffers: count)
        defer { free(listPtr.unsafeMutablePointer) }
        listPtr.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(count)

        var planeStorage: [UnsafeMutableRawPointer] = []
        defer { planeStorage.forEach { $0.deallocate() } }

        for index in 0..<count {
            let byteCount = planes[index].count * MemoryLayout<E>.stride
            let storage = UnsafeMutableRawPointer.allocate(
                byteCount: max(byteCount, 1),
                alignment: MemoryLayout<E>.alignment
            )
            planeStorage.append(storage)
            planes[index].withUnsafeBytes { raw in
                if let base = raw.baseAddress, byteCount > 0 {
                    storage.copyMemory(from: base, byteCount: byteCount)
                }
            }
            listPtr[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(byteCount),
                mData: storage
            )
        }

        return try body(UnsafePointer(listPtr.unsafeMutablePointer))
    }

    private func makePlanarFloat32(frames: Int, seed: UInt64) -> [Float] {
        makeInterleavedFloat32(frames: frames, channels: 1, seed: seed)
    }

    private func makePlanarInt16(frames: Int, seed: UInt64) -> [Int16] {
        makeInterleavedInt16(frames: frames, channels: 1, seed: seed)
    }

    private func planarASBD(channels: Int, isFloat: Bool, bits: UInt32, nonInterleaved: Bool) -> AudioStreamBasicDescription {
        var format = asbd(channels: channels, isFloat: isFloat, bits: bits)
        if nonInterleaved {
            format.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
            // Non-interleaved layout: bytes-per-frame describes a single channel.
            let bytesPerSample = UInt32(bits / 8)
            format.mBytesPerFrame = bytesPerSample
            format.mBytesPerPacket = bytesPerSample
        }
        return format
    }

    // MARK: - Builders

    private func asbd(channels: Int, isFloat: Bool, bits: UInt32) -> AudioStreamBasicDescription {
        let bytesPerSample = Int(bits / 8)
        let flags: AudioFormatFlags = isFloat
            ? (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian)
            : (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: UInt32(bytesPerSample * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerSample * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: bits,
            mReserved: 0
        )
    }

    private func makeInterleavedFloat32(frames: Int, channels: Int, seed: UInt64) -> [Float] {
        var rng = SplitMix64(seed: seed)
        return (0..<(frames * channels)).map { _ in
            // Range roughly [-1, 1) but with full float precision.
            Float(rng.nextUnitDouble() * 2 - 1)
        }
    }

    private func makeInterleavedInt16(frames: Int, channels: Int, seed: UInt64) -> [Int16] {
        var rng = SplitMix64(seed: seed)
        return (0..<(frames * channels)).map { _ in
            Int16(truncatingIfNeeded: Int(rng.next() & 0xFFFF) - 0x8000)
        }
    }

    private func floatArrayToBytes(_ floats: [Float]) -> [UInt8] {
        floats.withUnsafeBytes { Array($0) }
    }
}

/// Deterministic RNG so fixtures are stable across runs/platforms.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnitDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
