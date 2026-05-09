import Accelerate
import AVFoundation
import CoreMedia

// MARK: - Audio level extraction

struct AudioMeterFrame: Sendable {
    let peak: Float
    let bands: [Float]
}

enum AudioSpectrumConfiguration {
    static let bucketCount = 40
}

/// Peak amplitude + frequency buckets of a PCM `CMSampleBuffer`,
/// normalised to 0…1. Handles the two formats ScreenCaptureKit +
/// AVCaptureSession actually deliver on current macOS: 32-bit float
/// interleaved (SCStream default) and 16-bit signed integer
/// (AVCaptureSession microphones).
enum AudioLevelExtractor {
    /// Test-only hook so spectrum bucket tuning can be validated with
    /// deterministic synthetic signals.
    static func analyzeSamplesForTesting(
        _ samples: [Float],
        sampleRate: Double,
        bucketCount: Int = AudioSpectrumConfiguration.bucketCount
    ) -> [Float] {
        analyze(samples: samples, sampleRate: sampleRate, bucketCount: bucketCount).bands
    }

    static func meterFrame(
        _ sampleBuffer: CMSampleBuffer,
        bucketCount: Int = AudioSpectrumConfiguration.bucketCount
    ) -> AudioMeterFrame {
        guard bucketCount > 0 else {
            return AudioMeterFrame(peak: 0, bands: [])
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
        let maxMeterFrames = 4_096

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
                let mono = collapseToMono(frameCount: frameCount, channels: channels) { frame, channel in
                    let index = ((startFrame + frame) * channels) + channel
                    return index < count ? ptr[index] : 0
                }
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
                let mono = collapseToMono(frameCount: frameCount, channels: channels) { frame, channel in
                    let index = ((startFrame + frame) * channels) + channel
                    return index < count ? Float(ptr[index]) / 32768 : 0
                }
                return analyze(samples: mono, sampleRate: Double(asbd.mSampleRate), bucketCount: bucketCount)
            }
        }

        return silence(bucketCount: bucketCount)
    }

    private static func collapseToMono(
        frameCount: Int,
        channels: Int,
        sampleAt: (_ frame: Int, _ channel: Int) -> Float
    ) -> [Float] {
        guard frameCount > 0 else { return [] }
        return (0..<frameCount).map { frame in
            var sum: Float = 0
            for channel in 0..<channels {
                sum += sampleAt(frame, channel)
            }
            return sum / Float(channels)
        }
    }

    private static func analyze(samples: [Float], sampleRate: Double, bucketCount: Int) -> AudioMeterFrame {
        guard bucketCount > 0 else {
            return AudioMeterFrame(peak: 0, bands: [])
        }
        guard !samples.isEmpty else {
            return silence(bucketCount: bucketCount)
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            let peak = min(samples.reduce(Float(0)) { max($0, abs($1)) }, 1)
            return AudioMeterFrame(peak: peak, bands: Array(repeating: peak, count: bucketCount))
        }

        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }

        let fftSize = 2048
        guard samples.count >= 32 else {
            let clampedPeak = min(peak, 1)
            return AudioMeterFrame(peak: clampedPeak, bands: Array(repeating: clampedPeak, count: bucketCount))
        }

        let truncated = Array(samples.suffix(fftSize))
        let paddedSamples = truncated + Array(repeating: 0, count: max(0, fftSize - truncated.count))

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        let windowed = zip(paddedSamples, window).map(*)

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return AudioMeterFrame(peak: min(peak, 1), bands: Array(repeating: 0, count: bucketCount))
        }

        var inReal = windowed
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

        let halfCount = fftSize / 2
        let nyquist = sampleRate / 2
        let minFrequency = max(90.0, sampleRate / Double(fftSize))
        // This view is a compact "player-style" spectrum, not a lab-grade
        // analyzer. Cap the displayed range so typical music / speech spreads
        // across the whole width instead of leaving the right edge empty.
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

            var strongest: Float = 0
            var energySum: Float = 0
            var count: Int = 0

            for bin in 1..<halfCount {
                let frequency = (Double(bin) * sampleRate) / Double(fftSize)
                guard frequency >= lower, frequency < upper else { continue }
                let magnitude = hypot(outReal[bin], outImag[bin])
                strongest = max(strongest, magnitude)
                energySum += magnitude * magnitude
                count += 1
            }

            let rms = count > 0 ? sqrt(energySum / Float(count)) : 0
            let bucketEnergy = (rms * 0.78) + (strongest * 0.22)
            // Counterbalance the natural low-frequency bias of music / voice
            // so the compact visualizer behaves more like a traditional player.
            let spectralTiltCompensation = Float(pow(max(center, 140) / 140, 0.42))
            bandMagnitudes[bucketIndex] = bucketEnergy * spectralTiltCompensation
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

        return AudioMeterFrame(peak: min(peak, 1), bands: normalizedBands)
    }

    private static func silence(bucketCount: Int) -> AudioMeterFrame {
        AudioMeterFrame(peak: 0, bands: Array(repeating: 0, count: max(bucketCount, 0)))
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
