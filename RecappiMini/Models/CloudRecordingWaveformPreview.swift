import Foundation

@MainActor
final class CloudRecordingWaveformPreview: ObservableObject {
    @Published private(set) var waveformPeaks: [Float] = []
    @Published private(set) var isLoadingWaveform = false

    private var currentURL: URL?
    private var waveformTask: Task<Void, Never>?
    private var waveformCache: [URL: [Float]] = [:]

    deinit {
        waveformTask?.cancel()
    }

    func load(url: URL?) {
        guard currentURL != url else { return }
        waveformTask?.cancel()
        currentURL = url
        waveformPeaks = []
        isLoadingWaveform = false

        guard let url else { return }
        if let cached = waveformCache[url] {
            waveformPeaks = cached
            return
        }

        isLoadingWaveform = true
        waveformTask = Task { [url] in
            let peaks = await Task.detached(priority: .utility) {
                (try? PlaybackWaveformExtractor.cachedPeaks(from: url)) ?? []
            }.value
            guard !Task.isCancelled, self.currentURL == url else { return }
            self.waveformCache[url] = peaks
            self.waveformPeaks = peaks
            self.isLoadingWaveform = false
        }
    }
}
