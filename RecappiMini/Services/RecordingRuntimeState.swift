import Foundation

/// Runtime values that tick while an active recording is running.
///
/// These used to be `@Published` directly on `AudioRecorder`, which meant the
/// recorder's single `objectWillChange` fired for every meter publish (~20 Hz)
/// and elapsed-clock tick (1 Hz). Any view observing the recorder — including
/// the whole floating recording shell — was invalidated even if it only cared
/// about state, selected app, or actions.
///
/// Keeping the hot runtime values in their own observable lets the waveform and
/// timer subscribe narrowly while the rest of the panel observes `AudioRecorder`
/// only for slower semantic state changes.
@MainActor
final class RecordingRuntimeState: ObservableObject {
    @Published var elapsedSeconds: Int = 0
    @Published var audioLevel: Float = 0
    @Published var audioSpectrumLevels: [Float]
    @Published var audioLevelHistory: [Float]

    init(bucketCount: Int) {
        audioSpectrumLevels = Array(repeating: 0, count: bucketCount)
        audioLevelHistory = Array(repeating: 0, count: bucketCount)
    }

    func reset(bucketCount: Int) {
        elapsedSeconds = 0
        audioLevel = 0
        audioSpectrumLevels = Array(repeating: 0, count: bucketCount)
        audioLevelHistory = Array(repeating: 0, count: bucketCount)
    }
}
