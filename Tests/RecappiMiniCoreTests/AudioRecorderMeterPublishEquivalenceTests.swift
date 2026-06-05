import XCTest
@testable import RecappiMini

/// Perf-pass equivalence pin for the `AudioRecorder` meter publish path.
///
/// The optimization replaced two per-publish array allocations
/// (`audioSpectrumLevels.map { $0 * 0.72 }` + `zip(...).map(max)`) and a
/// per-frame `zip(pendingMeterBands, incoming).map(max)` allocation with
/// in-place element loops over reused storage. The values produced — and
/// the moments the `@Published` properties change — must be byte-for-byte
/// identical to the old code.
///
/// This test re-implements the ORIGINAL algorithm as an independent
/// reference model, drives the real `AudioRecorder` and the reference with
/// the SAME frame/timestamp stream across several publish windows, and
/// asserts the observable numeric output (`audioLevel`,
/// `audioSpectrumLevels`) matches exactly. If the in-place rewrite ever
/// diverges from the documented decay math (0.82 peak hold / 0.72 spectrum
/// decay, max-merge accumulation), this fails.
@MainActor
final class AudioRecorderMeterPublishEquivalenceTests: XCTestCase {
    /// Mirror of `AudioRecorder.spectrumBucketCount` for the reference.
    private let bucketCount = AudioRecorder.spectrumBucketCount

    /// Reference re-implementation of the pre-optimization meter publish
    /// pipeline. Kept deliberately allocation-naive (the way the old code
    /// was) so it is an obviously-correct oracle for the new in-place path.
    private struct ReferenceMeter {
        let bucketCount: Int
        let publishInterval: CFTimeInterval

        var level: Float = 0
        var spectrum: [Float]
        var pendingPeak: Float = 0
        var pendingBands: [Float]
        var lastPublish: CFTimeInterval = 0

        init(bucketCount: Int, publishInterval: CFTimeInterval) {
            self.bucketCount = bucketCount
            self.publishInterval = publishInterval
            self.spectrum = Array(repeating: 0, count: bucketCount)
            self.pendingBands = Array(repeating: 0, count: bucketCount)
        }

        // Exact copy of `AudioRecorder.normalizeSpectrum`.
        private func normalize(_ levels: [Float]) -> [Float] {
            if levels.count == bucketCount { return levels }
            if levels.count > bucketCount { return Array(levels.prefix(bucketCount)) }
            return levels + Array(repeating: 0, count: bucketCount - levels.count)
        }

        mutating func ingest(peak: Float, bands: [Float], now: CFTimeInterval) {
            let incoming = normalize(bands)
            if pendingBands.count != bucketCount {
                pendingBands = Array(repeating: 0, count: bucketCount)
            }
            pendingPeak = max(pendingPeak, peak)
            pendingBands = zip(pendingBands, incoming).map(max)

            let smoothed = max(level * 0.82, pendingPeak)

            if now - lastPublish >= publishInterval {
                lastPublish = now
                level = smoothed
                let decayed = spectrum.map { $0 * 0.72 }
                spectrum = zip(decayed, pendingBands).map(max)
                pendingPeak = 0
                pendingBands = Array(repeating: 0, count: bucketCount)
            }
        }
    }

    func testInPlaceMeterPublishMatchesAllocatingReference() {
        let recorder = AudioRecorder()
        // 1/20 == the intentional new publish cadence. The reference gates
        // on the same interval so the comparison isolates the per-frame /
        // per-publish *math*, not the cadence value.
        var reference = ReferenceMeter(bucketCount: bucketCount, publishInterval: 1.0 / 20.0)

        // A scripted stream that exercises: an opening publish, between-
        // publish accumulation (so max-merge matters), a silent frame that
        // must not erase accumulated peaks, varied per-band shapes (so the
        // element-wise decay/max is checked per index), and multiple
        // publish windows so the 0.72 spectrum decay compounds across
        // publishes and the 0.82 peak hold is exercised on a falling edge.
        func ramp(_ base: Float) -> [Float] {
            (0..<bucketCount).map { base * Float($0 % 7) / 6.0 }
        }
        let script: [(peak: Float, bands: [Float], now: CFTimeInterval)] = [
            (0.10, ramp(0.10), 0.00),   // accumulate (first window not yet open)
            (0.90, ramp(0.90), 0.01),   // accumulate (no publish)
            (0.30, ramp(0.30), 0.02),   // accumulate (no publish)
            (0.00, Array(repeating: 0, count: bucketCount), 0.06), // silent, crosses boundary -> publish
            (0.50, ramp(0.50), 0.07),   // accumulate (no publish)
            (0.20, ramp(0.20), 0.12),   // publish (decay compounds)
            (0.00, Array(repeating: 0, count: bucketCount), 0.18), // silent publish -> peak-hold falling edge
            (0.75, ramp(0.75), 0.19),   // accumulate (no publish)
            (0.05, ramp(0.05), 0.24),   // publish
        ]

        for step in script {
            reference.ingest(peak: step.peak, bands: step.bands, now: step.now)
            recorder.ingestMeterFrameForTesting(
                AudioMeterFrame(peak: step.peak, bands: step.bands),
                now: step.now
            )

            XCTAssertEqual(
                recorder.audioLevel,
                reference.level,
                "audioLevel diverged from the allocating reference at now=\(step.now)"
            )
            XCTAssertEqual(
                recorder.audioSpectrumLevels,
                reference.spectrum,
                "audioSpectrumLevels diverged from the allocating reference at now=\(step.now)"
            )
            XCTAssertEqual(
                recorder.audioSpectrumLevels.count,
                bucketCount,
                "publish must keep audioSpectrumLevels at spectrumBucketCount"
            )
        }
    }

    /// The reused scratch buffer must not survive a `reset()` — a fresh
    /// recording has to start the spectrum from zero, not from the last
    /// session's tail. Drives a publish, resets, then publishes a single
    /// silent frame: the reset zeroes `audioSpectrumLevels` and clears the
    /// publish timestamp, so the next frame opens a new window and the
    /// decay starts from 0.
    func testResetClearsAccumulatedMeterStateBeforeNextPublish() {
        let recorder = AudioRecorder()
        let loud = AudioMeterFrame(
            peak: 0.9,
            bands: Array(repeating: 0.9, count: bucketCount)
        )
        // now=1.0 clears the publish gate from the initial lastLevelPublish
        // of 0, so this frame publishes immediately.
        recorder.ingestMeterFrameForTesting(loud, now: 1.0)
        XCTAssertGreaterThan(recorder.audioSpectrumLevels.max() ?? 0, 0.8)

        recorder.reset()
        XCTAssertEqual(recorder.audioSpectrumLevels, Array(repeating: 0, count: bucketCount))
        XCTAssertEqual(recorder.audioLevel, 0)

        // First post-reset frame opens a fresh publish window (lastLevel-
        // Publish was zeroed) with a silent payload, so everything stays 0.
        let silent = AudioMeterFrame(
            peak: 0,
            bands: Array(repeating: 0, count: bucketCount)
        )
        recorder.ingestMeterFrameForTesting(silent, now: 100.0)
        XCTAssertEqual(recorder.audioLevel, 0)
        XCTAssertEqual(recorder.audioSpectrumLevels, Array(repeating: 0, count: bucketCount))
    }
}
