import Accelerate
import AVFoundation
import CoreMedia
import XCTest
@testable import RecappiCaptureCore

/// Proves the vDSP / scratch-buffer rewrite of `CaptureAudioLevelExtractor` stays
/// numerically equivalent to a from-scratch scalar reference, and that the two
/// concurrent capture-queue callers (`meterFrame`) can't corrupt the now-shared
/// FFT scratch.
final class CaptureAudioLevelExtractorTests: XCTestCase {
    private struct SendableSampleBuffer: @unchecked Sendable {
        let value: CMSampleBuffer
    }

    private final class MismatchCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    // MARK: - Scalar reference (mirrors the pre-optimization implementation)

    /// Recomputes the spectrum bands the slow, allocation-per-call way using
    /// `hypot` over each bin, so the optimized path can be diffed against it.
    private func referenceBands(samples: [Float], sampleRate: Double, bucketCount: Int) -> [Float] {
        guard bucketCount > 0, !samples.isEmpty else { return Array(repeating: 0, count: max(bucketCount, 0)) }

        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard sampleRate.isFinite, sampleRate > 0 else {
            return Array(repeating: min(peak, 1), count: bucketCount)
        }
        guard samples.count >= 32 else {
            return Array(repeating: min(peak, 1), count: bucketCount)
        }

        let fftSize = CaptureAudioSpectrumConfiguration.fftSize
        let halfCount = fftSize / 2
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return Array(repeating: 0, count: bucketCount)
        }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var inReal = [Float](repeating: 0, count: fftSize)
        let inputCount = min(samples.count, fftSize)
        let sourceStart = samples.count - inputCount
        for index in 0..<inputCount {
            inReal[index] = samples[sourceStart + index] * window[index]
        }
        var inImag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)

        inReal.withUnsafeMutableBufferPointer { inRealPtr in
            inImag.withUnsafeMutableBufferPointer { inImagPtr in
                outReal.withUnsafeMutableBufferPointer { outRealPtr in
                    outImag.withUnsafeMutableBufferPointer { outImagPtr in
                        let input = DSPSplitComplex(realp: inRealPtr.baseAddress!, imagp: inImagPtr.baseAddress!)
                        var output = DSPSplitComplex(realp: outRealPtr.baseAddress!, imagp: outImagPtr.baseAddress!)
                        fft.forward(input: input, output: &output)
                    }
                }
            }
        }

        // Reconstruct the same bucket layout the production plan uses.
        let nyquist = sampleRate / 2
        let minFrequency = max(90.0, sampleRate / Double(fftSize))
        let maxFrequency = max(min(nyquist, 8_000), minFrequency * 2)
        let minLogFrequency = log(minFrequency)
        let maxLogFrequency = log(maxFrequency)

        var bandMagnitudes = [Float](repeating: 0, count: bucketCount)
        for bucketIndex in 0..<bucketCount {
            let startT = Double(bucketIndex) / Double(bucketCount)
            let endT = Double(bucketIndex + 1) / Double(bucketCount)
            let lower = exp(minLogFrequency + ((maxLogFrequency - minLogFrequency) * startT))
            let upper = exp(minLogFrequency + ((maxLogFrequency - minLogFrequency) * endT))
            let center = sqrt(lower * upper)
            let tilt = Float(pow(max(center, 140) / 140, 0.42))

            var strongest: Float = 0
            var energySum: Float = 0
            var binCount = 0
            for bin in 1..<halfCount {
                let frequency = (Double(bin) * sampleRate) / Double(fftSize)
                if frequency >= lower, frequency < upper {
                    let magnitude = hypot(outReal[bin], outImag[bin])
                    strongest = max(strongest, magnitude)
                    energySum += magnitude * magnitude
                    binCount += 1
                }
            }
            let rms = binCount > 0 ? sqrt(energySum / Float(binCount)) : 0
            let bucketEnergy = (rms * 0.78) + (strongest * 0.22)
            bandMagnitudes[bucketIndex] = bucketEnergy * tilt
        }

        var smoothedBands = [Float]()
        for index in 0..<bandMagnitudes.count {
            let previous = bandMagnitudes[max(index - 1, 0)]
            let current = bandMagnitudes[index]
            let next = bandMagnitudes[min(index + 1, bandMagnitudes.count - 1)]
            smoothedBands.append((previous * 0.2) + (current * 0.6) + (next * 0.2))
        }

        let maxBand = max(smoothedBands.max() ?? 0, 0.0001)
        let amplitudeScale = min(1, sqrt(min(peak, 1)) * 1.55)
        var normalizedBands = [Float]()
        for index in 0..<smoothedBands.count {
            let magnitude = smoothedBands[index]
            let t = Float(index) / Float(max(bucketCount - 1, 1))
            let floorRatio: Float = 0.005
            let clamped = max(magnitude, maxBand * floorRatio)
            let decibels = 20 * log10(clamped / maxBand)
            let dbNormalized = max(0, min(1, (decibels + 46) / 46))
            let equalized = pow(dbNormalized, 0.88) * (0.78 + (0.92 * pow(t, 0.9)))
            normalizedBands.append(min(1, equalized * amplitudeScale))
        }
        return normalizedBands
    }

    // MARK: - Signal helpers

    private func sine(frequency: Double, sampleRate: Double, count: Int, amplitude: Float) -> [Float] {
        (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    private func mixedSine(components: [(Double, Float)], sampleRate: Double, count: Int) -> [Float] {
        (0..<count).map { index in
            var value: Float = 0
            for (frequency, amplitude) in components {
                value += amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
            }
            return value
        }
    }

    /// Build an interleaved CMSampleBuffer (float or int16) so `meterFrame`
    /// can be driven end-to-end, exercising the vDSP mono-collapse paths.
    private func makeSampleBuffer(
        interleaved channels: [[Float]],
        sampleRate: Double,
        asInt16: Bool
    ) throws -> CMSampleBuffer {
        let channelCount = channels.count
        let frameCount = channels.map(\.count).min() ?? 0
        XCTAssertGreaterThan(frameCount, 0)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: asInt16
                ? (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
                : (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked),
            mBytesPerPacket: UInt32((asInt16 ? MemoryLayout<Int16>.size : MemoryLayout<Float>.size) * channelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32((asInt16 ? MemoryLayout<Int16>.size : MemoryLayout<Float>.size) * channelCount),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: UInt32(asInt16 ? 16 : 32),
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        let fdStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        XCTAssertEqual(fdStatus, noErr)

        let bytesPerSample = asInt16 ? MemoryLayout<Int16>.size : MemoryLayout<Float>.size
        let dataLength = frameCount * channelCount * bytesPerSample
        var bytes = [UInt8](repeating: 0, count: dataLength)
        bytes.withUnsafeMutableBytes { rawBuffer in
            if asInt16 {
                let out = rawBuffer.bindMemory(to: Int16.self)
                for frame in 0..<frameCount {
                    for channel in 0..<channelCount {
                        let clamped = max(-1, min(1, channels[channel][frame]))
                        out[(frame * channelCount) + channel] = Int16(clamping: Int(clamped * 32_768))
                    }
                }
            } else {
                let out = rawBuffer.bindMemory(to: Float.self)
                for frame in 0..<frameCount {
                    for channel in 0..<channelCount {
                        out[(frame * channelCount) + channel] = channels[channel][frame]
                    }
                }
            }
        }

        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        XCTAssertEqual(bbStatus, kCMBlockBufferNoErr)
        let block = try XCTUnwrap(blockBuffer)
        bytes.withUnsafeBytes { rawBuffer in
            _ = CMBlockBufferReplaceDataBytes(
                with: rawBuffer.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataLength
            )
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(sbStatus, noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    // MARK: - Spectrum equivalence

    func testVDSPSpectrumMatchesScalarReferenceForSine() {
        let sampleRate = 48_000.0
        let samples = sine(frequency: 1_000, sampleRate: sampleRate, count: 4_096, amplitude: 0.8)

        let optimized = CaptureAudioLevelExtractor.analyzeSamplesForTesting(samples, sampleRate: sampleRate)
        let reference = referenceBands(samples: samples, sampleRate: sampleRate, bucketCount: CaptureAudioSpectrumConfiguration.bucketCount)

        XCTAssertEqual(optimized.count, reference.count)
        for (a, b) in zip(optimized, reference) {
            XCTAssertEqual(a, b, accuracy: 1e-3)
        }
    }

    func testVDSPSpectrumMatchesScalarReferenceForMixedTones() {
        let sampleRate = 48_000.0
        let samples = mixedSine(
            components: [(120, 0.6), (1_000, 0.5), (4_000, 0.4), (6_400, 0.3)],
            sampleRate: sampleRate,
            count: 3_000
        )

        let optimized = CaptureAudioLevelExtractor.analyzeSamplesForTesting(samples, sampleRate: sampleRate)
        let reference = referenceBands(samples: samples, sampleRate: sampleRate, bucketCount: CaptureAudioSpectrumConfiguration.bucketCount)

        XCTAssertEqual(optimized.count, reference.count)
        for (a, b) in zip(optimized, reference) {
            XCTAssertEqual(a, b, accuracy: 1e-3)
        }
    }

    func testVDSPSpectrumMatchesScalarReferenceWhenShorterThanFFT() {
        // Fewer samples than fftSize exercises the zero-padded tail path.
        let sampleRate = 44_100.0
        let samples = sine(frequency: 880, sampleRate: sampleRate, count: 512, amplitude: 0.5)

        let optimized = CaptureAudioLevelExtractor.analyzeSamplesForTesting(samples, sampleRate: sampleRate)
        let reference = referenceBands(samples: samples, sampleRate: sampleRate, bucketCount: CaptureAudioSpectrumConfiguration.bucketCount)

        for (a, b) in zip(optimized, reference) {
            XCTAssertEqual(a, b, accuracy: 1e-3)
        }
    }

    func testSilenceProducesAllZeroBands() {
        let bands = CaptureAudioLevelExtractor.analyzeSamplesForTesting(
            Array(repeating: 0, count: 4_096),
            sampleRate: 48_000
        )
        XCTAssertEqual(bands.count, CaptureAudioSpectrumConfiguration.bucketCount)
        XCTAssertTrue(bands.allSatisfy { $0 == 0 })
    }

    // MARK: - Peak (vDSP_maxmgv) via meterFrame end-to-end

    func testMeterFramePeakMatchesScalarMaxMagnitudeFloat() throws {
        let sampleRate = 48_000.0
        let left = sine(frequency: 1_000, sampleRate: sampleRate, count: 2_000, amplitude: 0.9)
        let right = sine(frequency: 1_000, sampleRate: sampleRate, count: 2_000, amplitude: 0.3)
        let buffer = try makeSampleBuffer(interleaved: [left, right], sampleRate: sampleRate, asInt16: false)

        let frame = CaptureAudioLevelExtractor.meterFrame(buffer)

        // Mono = (L + R) / 2; peak = max |mono|.
        let mono = zip(left, right).map { ($0 + $1) / 2 }
        let expectedPeak = min(mono.reduce(Float(0)) { max($0, abs($1)) }, 1)
        XCTAssertEqual(frame.peak, expectedPeak, accuracy: 1e-3)
    }

    func testCaptureLevelReportsRMSDecibelsForSystemInput() throws {
        let sampleRate = 48_000.0
        let samples = (0..<2_048).map { index in
            index.isMultiple(of: 2) ? Float(0.5) : Float(-0.5)
        }
        let buffer = try makeSampleBuffer(interleaved: [samples], sampleRate: sampleRate, asInt16: false)

        let level = CaptureAudioLevelExtractor.captureLevel(buffer, input: .system, atMs: 123)

        XCTAssertEqual(level.input, .system)
        XCTAssertEqual(level.atMs, 123)
        XCTAssertEqual(level.rmsDb, -6.0206, accuracy: 0.001)
    }

    func testCaptureLevelClampsSilenceToFloor() throws {
        let sampleRate = 48_000.0
        let samples = Array<Float>(repeating: 0, count: 2_048)
        let buffer = try makeSampleBuffer(interleaved: [samples], sampleRate: sampleRate, asInt16: false)

        let level = CaptureAudioLevelExtractor.captureLevel(buffer, input: .microphone, atMs: 456)

        XCTAssertEqual(level.input, .microphone)
        XCTAssertEqual(level.atMs, 456)
        XCTAssertLessThanOrEqual(level.rmsDb, -119)
    }

    func testMeterFrameSpectrumMatchesReferenceForStereoFloat() throws {
        let sampleRate = 48_000.0
        let left = mixedSine(components: [(200, 0.7), (2_000, 0.4)], sampleRate: sampleRate, count: 2_500)
        let right = mixedSine(components: [(200, 0.5), (5_000, 0.5)], sampleRate: sampleRate, count: 2_500)
        let buffer = try makeSampleBuffer(interleaved: [left, right], sampleRate: sampleRate, asInt16: false)

        let frame = CaptureAudioLevelExtractor.meterFrame(buffer)
        let mono = zip(left, right).map { ($0 + $1) / 2 }
        let reference = referenceBands(samples: mono, sampleRate: sampleRate, bucketCount: CaptureAudioSpectrumConfiguration.bucketCount)

        XCTAssertEqual(frame.bands.count, reference.count)
        for (a, b) in zip(frame.bands, reference) {
            XCTAssertEqual(a, b, accuracy: 1e-3)
        }
    }

    func testMeterFrameMonoCollapseMatchesReferenceForStereoInt16() throws {
        let sampleRate = 44_100.0
        let left = mixedSine(components: [(300, 0.6), (3_000, 0.4)], sampleRate: sampleRate, count: 2_200)
        let right = mixedSine(components: [(300, 0.4), (1_200, 0.5)], sampleRate: sampleRate, count: 2_200)
        let buffer = try makeSampleBuffer(interleaved: [left, right], sampleRate: sampleRate, asInt16: true)

        let frame = CaptureAudioLevelExtractor.meterFrame(buffer)

        // Reconstruct the exact int16 quantization the buffer used, then
        // collapse the same way the extractor does: (Float(s)/32768 averaged).
        func quantize(_ value: Float) -> Float {
            let clamped = max(-1, min(1, value))
            return Float(Int16(clamping: Int(clamped * 32_768))) / 32_768
        }
        let mono = zip(left, right).map { (quantize($0) + quantize($1)) / 2 }
        let reference = referenceBands(samples: mono, sampleRate: sampleRate, bucketCount: CaptureAudioSpectrumConfiguration.bucketCount)

        XCTAssertEqual(frame.bands.count, reference.count)
        for (a, b) in zip(frame.bands, reference) {
            XCTAssertEqual(a, b, accuracy: 2e-3)
        }
    }

    func testMeterFrameMonoCollapseMatchesReferenceForMonoFloat() throws {
        let sampleRate = 48_000.0
        let samples = mixedSine(components: [(440, 0.7), (1_760, 0.3)], sampleRate: sampleRate, count: 2_400)
        let buffer = try makeSampleBuffer(interleaved: [samples], sampleRate: sampleRate, asInt16: false)

        let frame = CaptureAudioLevelExtractor.meterFrame(buffer)
        let reference = referenceBands(samples: samples, sampleRate: sampleRate, bucketCount: CaptureAudioSpectrumConfiguration.bucketCount)

        for (a, b) in zip(frame.bands, reference) {
            XCTAssertEqual(a, b, accuracy: 1e-3)
        }
    }

    // MARK: - Concurrency: shared scratch must not corrupt across queues

    func testConcurrentMeterFrameStaysEquivalentToSerialResult() throws {
        let sampleRate = 48_000.0

        // Two distinct signals approximating the system-audio and mic queues.
        let systemSamples = mixedSine(components: [(180, 0.8), (2_400, 0.5)], sampleRate: sampleRate, count: 4_096)
        let micSamples = mixedSine(components: [(520, 0.6), (5_200, 0.45)], sampleRate: sampleRate, count: 4_096)
        let systemBuffer = SendableSampleBuffer(
            value: try makeSampleBuffer(interleaved: [systemSamples], sampleRate: sampleRate, asInt16: false)
        )
        let micBuffer = SendableSampleBuffer(
            value: try makeSampleBuffer(interleaved: [micSamples], sampleRate: sampleRate, asInt16: false)
        )

        // Golden serial results.
        let systemSerial = CaptureAudioLevelExtractor.meterFrame(systemBuffer.value).bands
        let micSerial = CaptureAudioLevelExtractor.meterFrame(micBuffer.value).bands

        let systemQueue = DispatchQueue(label: "test.system")
        let micQueue = DispatchQueue(label: "test.mic")
        let group = DispatchGroup()
        let mismatches = MismatchCounter()

        for _ in 0..<200 {
            group.enter()
            systemQueue.async {
                let bands = CaptureAudioLevelExtractor.meterFrame(systemBuffer.value).bands
                let ok = bands.count == systemSerial.count
                    && zip(bands, systemSerial).allSatisfy { abs($0 - $1) < 1e-3 }
                if !ok { mismatches.increment() }
                group.leave()
            }
            group.enter()
            micQueue.async {
                let bands = CaptureAudioLevelExtractor.meterFrame(micBuffer.value).bands
                let ok = bands.count == micSerial.count
                    && zip(bands, micSerial).allSatisfy { abs($0 - $1) < 1e-3 }
                if !ok { mismatches.increment() }
                group.leave()
            }
        }

        group.wait()
        // If the shared FFT scratch raced, results would diverge from the
        // golden serial run on at least some iterations.
        XCTAssertEqual(mismatches.value, 0)
    }
}
