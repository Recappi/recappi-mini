import CoreMedia
import RecappiCaptureCore

typealias AudioMeterFrame = CaptureAudioMeterFrame

enum AudioSpectrumConfiguration {
    static let bucketCount = CaptureAudioSpectrumConfiguration.bucketCount
    static let fftSize = CaptureAudioSpectrumConfiguration.fftSize
}

enum AudioLevelExtractor {
    static func analyzeSamplesForTesting(
        _ samples: [Float],
        sampleRate: Double,
        bucketCount: Int = AudioSpectrumConfiguration.bucketCount
    ) -> [Float] {
        CaptureAudioLevelExtractor.analyzeSamplesForTesting(
            samples,
            sampleRate: sampleRate,
            bucketCount: bucketCount
        )
    }

    static func meterFrame(
        _ sampleBuffer: CMSampleBuffer,
        bucketCount: Int = AudioSpectrumConfiguration.bucketCount
    ) -> AudioMeterFrame {
        CaptureAudioLevelExtractor.meterFrame(sampleBuffer, bucketCount: bucketCount)
    }
}
