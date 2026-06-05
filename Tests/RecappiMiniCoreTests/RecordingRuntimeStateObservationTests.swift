import Combine
import XCTest
@testable import RecappiMini

/// Perf regression pins for the recording runtime observer split.
///
/// The recording shell still observes `AudioRecorder` for semantic state
/// changes, but meter publishes run at ~20 Hz. Those hot values must live on
/// `RecordingRuntimeState` so they invalidate only waveform/timer subviews.
@MainActor
final class RecordingRuntimeStateObservationTests: XCTestCase {
    func testRuntimeTicksPublishRuntimeStateNotAudioRecorder() {
        var cancellables: Set<AnyCancellable> = []
        let recorder = AudioRecorder()
        let recorderDidPublish = expectation(description: "AudioRecorder should not publish runtime ticks")
        recorderDidPublish.isInverted = true
        recorder.objectWillChange
            .sink { _ in recorderDidPublish.fulfill() }
            .store(in: &cancellables)

        let runtimePublished = expectation(description: "runtime state publishes meter tick")
        recorder.runtimeState.$audioLevel
            .dropFirst()
            .sink { value in
                if value == 0.7 {
                    runtimePublished.fulfill()
                }
            }
            .store(in: &cancellables)

        recorder.elapsedSeconds = 12
        recorder.audioLevel = 0.7
        recorder.audioSpectrumLevels = Array(repeating: 0.4, count: AudioRecorder.spectrumBucketCount)
        recorder.audioLevelHistory = Array(repeating: 0.3, count: AudioRecorder.spectrumBucketCount)

        wait(for: [runtimePublished], timeout: 0.3)
        wait(for: [recorderDidPublish], timeout: 0.1)
    }

    func testLiveCaptionPanelStoreIgnoresMeterTicks() {
        var cancellables: Set<AnyCancellable> = []
        let recorder = AudioRecorder()
        let defaultsSuiteName = "RecordingRuntimeStateObservationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        defaults.set(false, forKey: "liveCaptionsBilingualEnabled")
        defaults.set("en-US", forKey: "speechLanguage")
        defaults.set("zh", forKey: "liveCaptionsTranslationTargetLanguage")

        let store = LiveCaptionPanelStore(recorder: recorder, defaults: defaults)
        // Drain KVO's initial defaults emissions so the assertion below
        // isolates meter churn rather than subscription setup noise.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let storeDidPublish = expectation(description: "caption panel store should ignore meter ticks")
        storeDidPublish.isInverted = true
        store.objectWillChange
            .sink { _ in storeDidPublish.fulfill() }
            .store(in: &cancellables)

        recorder.audioLevel = 0.8
        recorder.audioSpectrumLevels = Array(repeating: 0.6, count: AudioRecorder.spectrumBucketCount)
        recorder.audioLevelHistory = Array(repeating: 0.5, count: AudioRecorder.spectrumBucketCount)

        wait(for: [storeDidPublish], timeout: 0.1)
    }

    func testLiveCaptionPanelStorePublishesElapsedAndCaptionState() {
        var cancellables: Set<AnyCancellable> = []
        let recorder = AudioRecorder()
        let store = LiveCaptionPanelStore(recorder: recorder)

        let elapsedPublished = expectation(description: "elapsed time reaches panel store")
        store.$elapsedSeconds
            .dropFirst()
            .sink { value in
                if value == 8 {
                    elapsedPublished.fulfill()
                }
            }
            .store(in: &cancellables)
        recorder.elapsedSeconds = 8
        wait(for: [elapsedPublished], timeout: 0.3)

        let segment = LiveCaptionSegment(
            id: "caption-1",
            sourceText: "hello from the meeting",
            translatedText: nil,
            isFinal: false,
            sequence: 1
        )
        let segmentsPublished = expectation(description: "caption snapshot reaches panel store")
        store.$segments
            .dropFirst()
            .sink { value in
                if value == [segment] {
                    segmentsPublished.fulfill()
                }
            }
            .store(in: &cancellables)

        recorder.applyLiveCaptionSnapshotForTesting(
            LiveCaptionSnapshot(
                phase: .listening,
                segments: [segment],
                allSegmentsFinal: false,
                message: nil
            )
        )
        wait(for: [segmentsPublished], timeout: 0.3)
        XCTAssertEqual(store.statusPhase, .listening)
    }

}
