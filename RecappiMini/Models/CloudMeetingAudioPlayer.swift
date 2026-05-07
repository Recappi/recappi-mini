import AppKit
import AVFoundation
import Foundation
@preconcurrency import MediaPlayer

@MainActor
final class CloudMeetingAudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var waveformPeaks: [Float] = []
    @Published private(set) var isLoadingWaveform = false
    @Published private(set) var currentRecordingID: String?
    @Published private(set) var currentURL: URL?
    @Published private(set) var currentTitle = "Meeting playback"
    /// User-selected playback rate. Applied to `AVPlayer.rate` while
    /// playing; remembered across pause/play cycles so toggling
    /// playback never silently drops back to 1x.
    @Published private(set) var playbackRate: Float = 1.0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var waveformTask: Task<Void, Never>?
    private var waveformCache: [URL: [Float]] = [:]
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var currentArtwork: NSImage?
    private var isSeeking = false

    init() {
        configureRemoteCommands()
    }

    func load(recordingID: String?, url: URL?, title: String, artwork: NSImage?) {
        currentRecordingID = recordingID
        currentTitle = title
        currentArtwork = Self.normalizedArtwork(from: artwork)
        guard currentURL != url else {
            refreshDuration()
            updateNowPlayingInfo()
            return
        }

        removeObservers()
        player?.pause()
        player = nil
        currentRecordingID = recordingID
        currentURL = url
        currentTime = 0
        duration = 0
        isPlaying = false
        waveformTask?.cancel()
        waveformPeaks = []
        isLoadingWaveform = false
        updateNowPlayingInfo()

        guard let url else { return }

        let item = AVPlayerItem(url: url)
        // `.timeDomain` keeps pitch stable across non-1x rates so 0.5x
        // doesn't sound chipmunk-y (default `.lowQualityZeroLatency`
        // is fine for live HLS but rough on local file playback).
        item.audioTimePitchAlgorithm = .timeDomain
        let nextPlayer = AVPlayer(playerItem: item)
        player = nextPlayer
        refreshDuration()
        loadWaveform(for: url)

        timeObserver = nextPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.18, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard self?.isSeeking != true else { return }
                self?.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                self?.refreshDuration()
                self?.updateNowPlayingInfo()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.seek(to: 0)
                self?.updateNowPlayingInfo()
            }
        }
        updateNowPlayingInfo()
    }

    func play() {
        guard let player else { return }
        // `play()` always resumes at 1x; honour the user's saved rate
        // by stamping it after the play call. Setting `rate` while
        // paused is harmless because we only do it on a player that
        // just transitioned to playing.
        player.play()
        if playbackRate != 1.0 {
            player.rate = playbackRate
        }
        isPlaying = true
        refreshDuration()
        updateNowPlayingInfo()
    }

    /// Update the user-preferred playback rate. Applied immediately
    /// when audio is currently playing; otherwise stored so the next
    /// `play()` call picks it up.
    func setPlaybackRate(_ rate: Float) {
        let clamped = max(0.25, min(rate, 4.0))
        playbackRate = clamped
        guard isPlaying, let player else { return }
        player.rate = clamped
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func close() {
        removeObservers()
        waveformTask?.cancel()
        waveformTask = nil
        player?.pause()
        player = nil
        currentRecordingID = nil
        currentURL = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        waveformPeaks = []
        isLoadingWaveform = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, max(duration, seconds)))
        currentTime = clamped
        guard let player else {
            updateNowPlayingInfo()
            return
        }

        isSeeking = true
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = clamped
                self.isSeeking = false
                self.refreshDuration()
                self.updateNowPlayingInfo()
            }
        }
        updateNowPlayingInfo()
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    private func refreshDuration() {
        let seconds = player?.currentItem?.duration.seconds ?? 0
        if seconds.isFinite, seconds > 0 {
            duration = seconds
        }
    }

    private func updateNowPlayingInfo() {
        guard currentURL != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyArtist: "Recappi",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0.0,
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let currentArtwork {
            info[MPMediaItemPropertyArtwork] = Self.makeNowPlayingArtwork(from: currentArtwork)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private nonisolated static func makeNowPlayingArtwork(from image: NSImage) -> MPMediaItemArtwork {
        let artworkImage = (image.copy() as? NSImage) ?? image
        // MediaPlayer evaluates this provider on a background queue; keep it nonisolated so Swift actor checks do not trap.
        return MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in
            artworkImage
        }
    }

    private static func normalizedArtwork(from image: NSImage?) -> NSImage? {
        guard let image else { return nil }

        let canvasSize = NSSize(width: 256, height: 256)
        let canvas = NSImage(size: canvasSize)
        canvas.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: canvasSize).fill()

        let inset: CGFloat = 18
        image.draw(
            in: NSRect(x: inset, y: inset, width: canvasSize.width - inset * 2, height: canvasSize.height - inset * 2),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        canvas.unlockFocus()
        return canvas
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        remoteCommandTargets = [
            (
                commandCenter.playCommand,
                commandCenter.playCommand.addTarget { [weak self] _ in
                    Task { @MainActor in self?.play() }
                    return .success
                }
            ),
            (
                commandCenter.pauseCommand,
                commandCenter.pauseCommand.addTarget { [weak self] _ in
                    Task { @MainActor in self?.pause() }
                    return .success
                }
            ),
            (
                commandCenter.togglePlayPauseCommand,
                commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
                    Task { @MainActor in self?.togglePlayback() }
                    return .success
                }
            ),
            (
                commandCenter.changePlaybackPositionCommand,
                commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
                    guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                        return .commandFailed
                    }
                    Task { @MainActor in self?.seek(to: event.positionTime) }
                    return .success
                }
            ),
        ]
    }

    private func loadWaveform(for url: URL) {
        if let cached = waveformCache[url] {
            waveformPeaks = cached
            return
        }

        isLoadingWaveform = true
        waveformTask = Task { [url] in
            let peaks = await Task.detached(priority: .utility) {
                (try? PlaybackWaveformExtractor.cachedPeaks(from: url)) ?? []
            }.value
            guard currentURL == url, !Task.isCancelled else { return }
            waveformCache[url] = peaks
            waveformPeaks = peaks
            isLoadingWaveform = false
        }
    }

    private func removeObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }
}
