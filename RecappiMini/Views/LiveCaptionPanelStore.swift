import Combine
import Foundation

/// Narrow observable for the floating live-caption panel.
///
/// `AudioRecorder` publishes many hot values while recording: meter peak,
/// spectrum bands, history, elapsed time, recording state, caption snapshots,
/// etc. The live-caption panel only needs caption state plus a 1 Hz elapsed
/// clock. Observing the whole recorder makes every meter tick invalidate the
/// caption panel tree, even when no caption text changed.
///
/// This store subscribes only to the fields the panel renders and republishes
/// that smaller model. Meter/audio-level churn stays on `AudioRecorder` and no
/// longer wakes the caption view.
@MainActor
final class LiveCaptionPanelStore: ObservableObject {
    @Published private(set) var elapsedSeconds: Int
    @Published private(set) var segments: [LiveCaptionSegment]
    @Published private(set) var message: String?
    @Published private(set) var statusPhase: LiveCaptionSnapshot.Phase?
    @Published private(set) var activeConfiguration: LiveCaptionRecordingConfiguration?
    @Published private(set) var canReconnect: Bool
    @Published private(set) var fallbackShowsTranslation: Bool
    @Published private(set) var cloudLanguage: String
    @Published private(set) var fallbackTargetLanguage: String

    private weak var recorder: AudioRecorder?
    private var cancellables: Set<AnyCancellable> = []

    init(recorder: AudioRecorder, defaults: UserDefaults = .standard) {
        self.recorder = recorder
        elapsedSeconds = recorder.elapsedSeconds
        segments = recorder.liveCaptionSegments
        message = recorder.liveCaptionMessage
        statusPhase = recorder.liveCaptionStatusPhase
        activeConfiguration = recorder.activeLiveCaptionConfiguration
        canReconnect = recorder.canReconnectLiveCaptions
        fallbackShowsTranslation = defaults.liveCaptionsBilingualEnabled
        cloudLanguage = defaults.speechLanguage ?? "en-US"
        fallbackTargetLanguage = defaults.liveCaptionsTranslationTargetLanguage ?? "zh"

        recorder.runtimeState.$elapsedSeconds
            .removeDuplicates()
            .sink { [weak self] value in
                self?.elapsedSeconds = value
            }
            .store(in: &cancellables)

        recorder.$liveCaptionSegments
            .removeDuplicates()
            .sink { [weak self] value in
                self?.segments = value
            }
            .store(in: &cancellables)

        recorder.$liveCaptionMessage
            .removeDuplicates()
            .sink { [weak self] value in
                self?.message = value
            }
            .store(in: &cancellables)

        recorder.$liveCaptionStatusPhase
            .removeDuplicates()
            .sink { [weak self] value in
                self?.statusPhase = value
                self?.refreshCanReconnect()
            }
            .store(in: &cancellables)

        recorder.$activeLiveCaptionConfiguration
            .removeDuplicates()
            .sink { [weak self] value in
                self?.activeConfiguration = value
                self?.refreshCanReconnect()
            }
            .store(in: &cancellables)

        recorder.$liveCaptionLifecycleRevision
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshCanReconnect()
            }
            .store(in: &cancellables)

        recorder.$state
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshCanReconnect()
            }
            .store(in: &cancellables)

        defaults.publisher(for: \.liveCaptionsBilingualEnabled)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.fallbackShowsTranslation = value
            }
            .store(in: &cancellables)

        defaults.publisher(for: \.speechLanguage)
            .map { $0 ?? "en-US" }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.cloudLanguage = value
            }
            .store(in: &cancellables)

        defaults.publisher(for: \.liveCaptionsTranslationTargetLanguage)
            .map { $0 ?? "zh" }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.fallbackTargetLanguage = value
            }
            .store(in: &cancellables)
    }

    func reconnectLiveCaptionsNow() {
        recorder?.reconnectLiveCaptionsNow()
        refreshCanReconnect()
    }

    private func refreshCanReconnect() {
        canReconnect = recorder?.canReconnectLiveCaptions ?? false
    }
}

extension UserDefaults {
    @objc dynamic var liveCaptionsBilingualEnabled: Bool {
        bool(forKey: "liveCaptionsBilingualEnabled")
    }

    @objc dynamic var speechLanguage: String? {
        string(forKey: "speechLanguage")
    }

    @objc dynamic var liveCaptionsTranslationTargetLanguage: String? {
        string(forKey: "liveCaptionsTranslationTargetLanguage")
    }
}
