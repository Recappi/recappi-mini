import Accelerate
import AVFoundation
import CoreMedia

// MARK: - Audio level extraction

public struct CaptureAudioMeterFrame: Sendable, Equatable {
    public let peak: Float
    public let bands: [Float]

    public init(peak: Float, bands: [Float]) {
        self.peak = peak
        self.bands = bands
    }
}

public enum CaptureAudioSpectrumConfiguration {
    public static let bucketCount = 40
    public static let fftSize = 2_048
}

private final class AudioSpectrumAnalysisPlan: @unchecked Sendable {
    struct Bucket {
        let bins: [Int]
        let tilt: Float
    }

    private struct Key: Hashable {
        let sampleRate: Int
        let bucketCount: Int
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: AudioSpectrumAnalysisPlan] = [:]

    let window: [Float]
    let buckets: [Bucket]
    private let fft: vDSP.FFT<DSPSplitComplex>

    // `computeLock` guards both the FFT plan (which is not documented as
    // re-entrant) and the persistent scratch buffers below. `meterFrame` runs
    // concurrently on two capture queues (system audio + microphone), so the
    // shared scratch must not be touched by both at once. Serializing the
    // ~24 short FFTs/sec each queue produces is cheap and keeps the buffers
    // race-free without per-frame allocation.
    private let computeLock = NSLock()

    // Persistent FFT scratch, reused across frames instead of allocating four
    // `[Float]` of `fftSize` (plus a magnitude buffer) on every gated frame.
    // Only ever read/written while holding `computeLock`.
    private var inReal: [Float]
    private var inImag: [Float]
    private var outReal: [Float]
    private var outImag: [Float]
    private var magnitudes: [Float]

    static func plan(sampleRate: Double, bucketCount: Int) -> AudioSpectrumAnalysisPlan? {
        let key = Key(sampleRate: Int(sampleRate.rounded()), bucketCount: bucketCount)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[key] {
            return cached
        }
        guard let created = AudioSpectrumAnalysisPlan(sampleRate: sampleRate, bucketCount: bucketCount) else {
            return nil
        }
        cache[key] = created
        return created
    }

    private init?(sampleRate: Double, bucketCount: Int) {
        let fftSize = CaptureAudioSpectrumConfiguration.fftSize
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return nil
        }
        self.fft = fft

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = window

        let halfCount = fftSize / 2
        self.inReal = [Float](repeating: 0, count: fftSize)
        self.inImag = [Float](repeating: 0, count: fftSize)
        self.outReal = [Float](repeating: 0, count: fftSize)
        self.outImag = [Float](repeating: 0, count: fftSize)
        self.magnitudes = [Float](repeating: 0, count: halfCount)

        let nyquist = sampleRate / 2
        let minFrequency = max(90.0, sampleRate / Double(fftSize))
        // This view is a compact "player-style" spectrum, not a lab-grade
        // analyzer. Cap the displayed range so typical music / speech spreads
        // across the whole width instead of leaving the right edge empty.
        let maxFrequency = max(min(nyquist, 8_000), minFrequency * 2)
        let minLogFrequency = log(minFrequency)
        let maxLogFrequency = log(maxFrequency)

        self.buckets = (0..<bucketCount).map { bucketIndex in
            let startT = Double(bucketIndex) / Double(bucketCount)
            let endT = Double(bucketIndex + 1) / Double(bucketCount)
            let lower = exp(minLogFrequency + ((maxLogFrequency - minLogFrequency) * startT))
            let upper = exp(minLogFrequency + ((maxLogFrequency - minLogFrequency) * endT))
            let center = sqrt(lower * upper)

            var bins: [Int] = []
            bins.reserveCapacity(halfCount / max(bucketCount, 1))
            for bin in 1..<halfCount {
                let frequency = (Double(bin) * sampleRate) / Double(fftSize)
                if frequency >= lower, frequency < upper {
                    bins.append(bin)
                }
            }

            return Bucket(
                bins: bins,
                tilt: Float(pow(max(center, 140) / 140, 0.42))
            )
        }
    }

    /// Window `samples` (last `fftSize` of them), run the real FFT, and return
    /// the per-bin magnitudes (`hypot(re, im)`) for bins `0..<fftSize/2`.
    ///
    /// The closure receives the magnitude buffer while `computeLock` is still
    /// held so the shared scratch cannot be reused by the other capture queue
    /// mid-read; callers must finish reading before returning.
    func magnitudeSpectrum<Result>(
        of samples: [Float],
        _ body: (_ magnitudes: UnsafeBufferPointer<Float>) -> Result
    ) -> Result {
        let fftSize = CaptureAudioSpectrumConfiguration.fftSize
        let halfCount = fftSize / 2

        computeLock.lock()
        defer { computeLock.unlock() }

        let inputCount = min(samples.count, fftSize)
        let sourceStart = samples.count - inputCount

        // Window the most-recent `inputCount` samples (windowed = samples *
        // Hann) with vDSP instead of a scalar multiply loop, then zero the
        // unused tail of the real buffer so stale data from a longer previous
        // frame can't leak in.
        inReal.withUnsafeMutableBufferPointer { inRealPtr in
            samples.withUnsafeBufferPointer { samplePtr in
                window.withUnsafeBufferPointer { windowPtr in
                    if inputCount > 0 {
                        vDSP_vmul(
                            samplePtr.baseAddress! + sourceStart, 1,
                            windowPtr.baseAddress!, 1,
                            inRealPtr.baseAddress!, 1,
                            vDSP_Length(inputCount)
                        )
                    }
                }
            }
            if inputCount < fftSize {
                vDSP_vclr(inRealPtr.baseAddress! + inputCount, 1, vDSP_Length(fftSize - inputCount))
            }
        }
        // Imaginary input is always zero for a real signal; clear it in case a
        // prior FFT wrote into the split-complex output aliasing scratch.
        inImag.withUnsafeMutableBufferPointer { ptr in
            vDSP_vclr(ptr.baseAddress!, 1, vDSP_Length(fftSize))
        }

        return inReal.withUnsafeMutableBufferPointer { inRealPtr in
            inImag.withUnsafeMutableBufferPointer { inImagPtr in
                outReal.withUnsafeMutableBufferPointer { outRealPtr in
                    outImag.withUnsafeMutableBufferPointer { outImagPtr in
                        let input = DSPSplitComplex(realp: inRealPtr.baseAddress!, imagp: inImagPtr.baseAddress!)
                        var output = DSPSplitComplex(realp: outRealPtr.baseAddress!, imagp: outImagPtr.baseAddress!)
                        fft.forward(input: input, output: &output)
                        return magnitudes.withUnsafeMutableBufferPointer { magPtr in
                            // |bin| = hypot(re, im); vDSP_zvabs computes exactly
                            // sqrt(re^2 + im^2) per element, matching the prior
                            // scalar `hypot` loop.
                            vDSP_zvabs(&output, 1, magPtr.baseAddress!, 1, vDSP_Length(halfCount))
                            return body(UnsafeBufferPointer(magPtr))
                        }
                    }
                }
            }
        }
    }
}

/// Peak amplitude + frequency buckets of a PCM `CMSampleBuffer`,
/// normalised to 0…1. Handles the two formats ScreenCaptureKit +
/// AVCaptureSession actually deliver on current macOS: 32-bit float
/// interleaved (SCStream default) and 16-bit signed integer
/// (AVCaptureSession microphones).
public enum CaptureAudioLevelExtractor {
    /// Test-only hook so spectrum bucket tuning can be validated with
    /// deterministic synthetic signals.
    public static func analyzeSamplesForTesting(
        _ samples: [Float],
        sampleRate: Double,
        bucketCount: Int = CaptureAudioSpectrumConfiguration.bucketCount
    ) -> [Float] {
        analyze(samples: samples, sampleRate: sampleRate, bucketCount: bucketCount).bands
    }

    public static func meterFrame(
        _ sampleBuffer: CMSampleBuffer,
        bucketCount: Int = CaptureAudioSpectrumConfiguration.bucketCount
    ) -> CaptureAudioMeterFrame {
        guard bucketCount > 0 else {
            return CaptureAudioMeterFrame(peak: 0, bands: [])
        }
        guard
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
            let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else {
            return silence(bucketCount: bucketCount)
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let raw = dataPointer, totalLength > 0 else {
            return silence(bucketCount: bucketCount)
        }

        let asbd = asbdPtr.pointee
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let channels = Int(asbd.mChannelsPerFrame)
        guard (1...32).contains(channels),
              asbd.mSampleRate.isFinite,
              asbd.mSampleRate > 0 else {
            return silence(bucketCount: bucketCount)
        }

        let declaredFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        let maxMeterFrames = CaptureAudioSpectrumConfiguration.fftSize

        if isFloat, asbd.mBitsPerChannel == 32 {
            let rawSampleCount = totalLength / MemoryLayout<Float>.size
            let declaredSampleCount = safeDeclaredSampleCount(
                declaredFrames: declaredFrames,
                channels: channels,
                fallback: rawSampleCount
            )
            let count = min(rawSampleCount, declaredSampleCount)
            guard count > 0 else { return silence(bucketCount: bucketCount) }
            return raw.withMemoryRebound(to: Float.self, capacity: count) { ptr in
                let totalFrames = count / channels
                let frameCount = min(totalFrames, maxMeterFrames)
                let startFrame = max(totalFrames - frameCount, 0)
                let mono = collapseFloatToMono(
                    base: ptr + (startFrame * channels),
                    frameCount: frameCount,
                    channels: channels,
                    available: count - (startFrame * channels)
                )
                return analyze(samples: mono, sampleRate: Double(asbd.mSampleRate), bucketCount: bucketCount)
            }
        }

        if asbd.mBitsPerChannel == 16 {
            let rawSampleCount = totalLength / MemoryLayout<Int16>.size
            let declaredSampleCount = safeDeclaredSampleCount(
                declaredFrames: declaredFrames,
                channels: channels,
                fallback: rawSampleCount
            )
            let count = min(rawSampleCount, declaredSampleCount)
            guard count > 0 else { return silence(bucketCount: bucketCount) }
            return raw.withMemoryRebound(to: Int16.self, capacity: count) { ptr in
                let totalFrames = count / channels
                let frameCount = min(totalFrames, maxMeterFrames)
                let startFrame = max(totalFrames - frameCount, 0)
                let mono = collapseInt16ToMono(
                    base: ptr + (startFrame * channels),
                    frameCount: frameCount,
                    channels: channels,
                    available: count - (startFrame * channels)
                )
                return analyze(samples: mono, sampleRate: Double(asbd.mSampleRate), bucketCount: bucketCount)
            }
        }

        return silence(bucketCount: bucketCount)
    }

    /// Collapse interleaved 32-bit float frames to a mono buffer
    /// (`mean across channels`), matching the previous scalar averaging.
    ///
    /// `base` must point at the first sample of the first frame to read;
    /// `available` is the number of valid `Float` samples remaining from `base`
    /// (so a truncated final frame reads 0 for the missing channels, exactly as
    /// the old closure-based path did).
    private static func collapseFloatToMono(
        base: UnsafePointer<Float>,
        frameCount: Int,
        channels: Int,
        available: Int
    ) -> [Float] {
        guard frameCount > 0 else { return [] }
        var mono = [Float](repeating: 0, count: frameCount)
        let invChannels = 1 / Float(channels)

        // Fast path: the buffer holds every channel of every frame we read.
        // Sum the channels with vDSP_vadd then scale by 1/channels.
        if available >= frameCount * channels {
            mono.withUnsafeMutableBufferPointer { out in
                if channels == 1 {
                    vDSP_vsmul(base, 1, [invChannels], out.baseAddress!, 1, vDSP_Length(frameCount))
                    return
                }
                // Seed the accumulator with channel 0 (stride = channels), then
                // add each remaining channel in place.
                vDSP_vsadd(base, channels, [0], out.baseAddress!, 1, vDSP_Length(frameCount))
                for channel in 1..<channels {
                    vDSP_vadd(
                        base + channel, channels,
                        out.baseAddress!, 1,
                        out.baseAddress!, 1,
                        vDSP_Length(frameCount)
                    )
                }
                vDSP_vsmul(out.baseAddress!, 1, [invChannels], out.baseAddress!, 1, vDSP_Length(frameCount))
            }
            return mono
        }

        // Slow path: a truncated trailing frame. Mirror the old behaviour of
        // treating out-of-range channels as 0 before averaging.
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channels {
                let index = (frame * channels) + channel
                sum += index < available ? base[index] : 0
            }
            mono[frame] = sum * invChannels
        }
        return mono
    }

    /// Collapse interleaved 16-bit signed integer frames to a normalised mono
    /// buffer (`Float(sample) / 32768`, averaged across channels), matching the
    /// previous scalar averaging. See `collapseFloatToMono` for the `available`
    /// contract.
    private static func collapseInt16ToMono(
        base: UnsafePointer<Int16>,
        frameCount: Int,
        channels: Int,
        available: Int
    ) -> [Float] {
        guard frameCount > 0 else { return [] }
        var mono = [Float](repeating: 0, count: frameCount)
        // Average then normalise: (sum / channels) / 32768.
        let scale = 1 / (Float(channels) * 32_768)

        if available >= frameCount * channels {
            mono.withUnsafeMutableBufferPointer { out in
                if channels == 1 {
                    vDSP_vflt16(base, 1, out.baseAddress!, 1, vDSP_Length(frameCount))
                } else {
                    // Convert + sum channels. Use a single-channel temp because
                    // vDSP integer→float conversion has no strided accumulate.
                    var temp = [Float](repeating: 0, count: frameCount)
                    temp.withUnsafeMutableBufferPointer { tmp in
                        vDSP_vflt16(base, channels, out.baseAddress!, 1, vDSP_Length(frameCount))
                        for channel in 1..<channels {
                            vDSP_vflt16(base + channel, channels, tmp.baseAddress!, 1, vDSP_Length(frameCount))
                            vDSP_vadd(
                                out.baseAddress!, 1,
                                tmp.baseAddress!, 1,
                                out.baseAddress!, 1,
                                vDSP_Length(frameCount)
                            )
                        }
                    }
                }
                vDSP_vsmul(out.baseAddress!, 1, [scale], out.baseAddress!, 1, vDSP_Length(frameCount))
            }
            return mono
        }

        // Slow path: truncated trailing frame. Out-of-range channels read 0.
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channels {
                let index = (frame * channels) + channel
                sum += index < available ? Float(base[index]) : 0
            }
            mono[frame] = sum * scale
        }
        return mono
    }

    private static func analyze(samples: [Float], sampleRate: Double, bucketCount: Int) -> CaptureAudioMeterFrame {
        guard bucketCount > 0 else {
            return CaptureAudioMeterFrame(peak: 0, bands: [])
        }
        guard !samples.isEmpty else {
            return silence(bucketCount: bucketCount)
        }

        // Peak = max(|sample|). vDSP_maxmgv computes the maximum magnitude in a
        // single pass, replacing the scalar `reduce(max(abs))`.
        var peak: Float = 0
        samples.withUnsafeBufferPointer { ptr in
            vDSP_maxmgv(ptr.baseAddress!, 1, &peak, vDSP_Length(ptr.count))
        }

        guard sampleRate.isFinite, sampleRate > 0 else {
            return CaptureAudioMeterFrame(peak: min(peak, 1), bands: Array(repeating: min(peak, 1), count: bucketCount))
        }

        guard samples.count >= 32 else {
            let clampedPeak = min(peak, 1)
            return CaptureAudioMeterFrame(peak: clampedPeak, bands: Array(repeating: clampedPeak, count: bucketCount))
        }
        guard let plan = AudioSpectrumAnalysisPlan.plan(sampleRate: sampleRate, bucketCount: bucketCount) else {
            return CaptureAudioMeterFrame(peak: min(peak, 1), bands: Array(repeating: 0, count: bucketCount))
        }

        var bandMagnitudes = [Float](repeating: 0, count: bucketCount)

        // Window + FFT + per-bin magnitude happen on shared scratch under the
        // plan's lock; the per-bucket reduction reads from the magnitude buffer
        // while the lock is still held.
        plan.magnitudeSpectrum(of: samples) { magnitude in
            for (bucketIndex, bucket) in plan.buckets.enumerated() {
                var strongest: Float = 0
                var energySum: Float = 0

                for bin in bucket.bins {
                    let value = magnitude[bin]
                    strongest = max(strongest, value)
                    energySum += value * value
                }

                let count = bucket.bins.count
                let rms = count > 0 ? sqrt(energySum / Float(count)) : 0
                let bucketEnergy = (rms * 0.78) + (strongest * 0.22)
                // Counterbalance the natural low-frequency bias of music / voice
                // so the compact visualizer behaves more like a traditional player.
                bandMagnitudes[bucketIndex] = bucketEnergy * bucket.tilt
            }
        }

        var smoothedBands = [Float]()
        smoothedBands.reserveCapacity(bucketCount)
        for index in 0..<bandMagnitudes.count {
            let previous = bandMagnitudes[max(index - 1, 0)]
            let current = bandMagnitudes[index]
            let next = bandMagnitudes[min(index + 1, bandMagnitudes.count - 1)]
            smoothedBands.append((previous * 0.2) + (current * 0.6) + (next * 0.2))
        }

        let maxBand = max(smoothedBands.max() ?? 0, 0.0001)
        let amplitudeScale = min(1, sqrt(min(peak, 1)) * 1.55)
        var normalizedBands = [Float]()
        normalizedBands.reserveCapacity(smoothedBands.count)
        for index in 0..<smoothedBands.count {
            let magnitude = smoothedBands[index]
            let t = Float(index) / Float(max(bucketCount - 1, 1))
            let floorRatio: Float = 0.005   // ~ -46 dB floor
            let clamped = max(magnitude, maxBand * floorRatio)
            let decibels = 20 * log10(clamped / maxBand)
            let dbNormalized = max(0, min(1, (decibels + 46) / 46))
            let equalized = pow(dbNormalized, 0.88) * (0.78 + (0.92 * pow(t, 0.9)))
            normalizedBands.append(min(1, equalized * amplitudeScale))
        }

        return CaptureAudioMeterFrame(peak: min(peak, 1), bands: normalizedBands)
    }

    private static func silence(bucketCount: Int) -> CaptureAudioMeterFrame {
        CaptureAudioMeterFrame(peak: 0, bands: Array(repeating: 0, count: max(bucketCount, 0)))
    }

    private static func safeDeclaredSampleCount(
        declaredFrames: Int,
        channels: Int,
        fallback: Int
    ) -> Int {
        guard declaredFrames > 0 else { return fallback }
        let multiplied = declaredFrames.multipliedReportingOverflow(by: channels)
        return multiplied.overflow ? fallback : multiplied.partialValue
    }
}
