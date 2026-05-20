import SwiftUI

struct CloudMeetingPlaybackStrip: View {
    let isPlaying: Bool
    let currentTime: Double
    let duration: Double
    let sourceDescription: String
    let errorMessage: String?
    let isPreparingAudio: Bool
    let hasAudio: Bool
    let isViewingLoadedAudio: Bool
    let hasLocalSession: Bool
    let waveformPeaks: [Float]
    let isLoadingWaveform: Bool
    let playbackRate: Float
    let onPlayPause: () -> Void
    let onSeek: (Double) -> Void
    let onSelectRate: (Float) -> Void

    @State private var rateSelectionFeedbackID = 0

    /// Allowed playback rates surfaced in the menu. Order matters -
    /// the menu renders top-to-bottom in this order.
    private static let rateOptions: [Float] = [0.5, 1.0, 1.5, 2.0, 3.0]

    private var sliderUpperBound: Double {
        max(duration, currentTime, 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlayPause) {
                ZStack {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .medium))
                        .opacity(isPreparingAudio ? 0 : 1)
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .opacity(isPreparingAudio ? 1 : 0)
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(PanelIconButtonStyle(size: 28))
            .disabled(isPreparingAudio)
            .help(hasAudio ? "Play meeting audio" : "Download audio preview")

            VStack(alignment: .leading, spacing: 2) {
                Text(playbackStatusTitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(playbackStatusColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(playbackStatusDetail)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 150, alignment: .leading)

            CloudPlaybackWaveformScrubber(
                progress: sliderProgress,
                isEnabled: hasAudio && !isPreparingAudio,
                peaks: waveformPeaks,
                isLoadingPeaks: isLoadingWaveform,
                onSeekProgress: { progress in
                    onSeek(progress * sliderUpperBound)
                }
            )

            playbackRateMenu
        }
        .frame(height: 44)
        .padding(.horizontal, 14)
        // Liquid Glass mini-player capsule, modelled on Apple Music's
        // bottom now-playing bar: the strip floats over the content
        // behind it instead of slabbing across the whole pane edge.
        .glassEffect(in: Capsule(style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    private var sliderProgress: Double {
        guard sliderUpperBound > 0 else { return 0 }
        return min(max(0, currentTime / sliderUpperBound), 1)
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach(Self.rateOptions, id: \.self) { rate in
                Button {
                    onSelectRate(rate)
                    rateSelectionFeedbackID += 1
                } label: {
                    if rate == playbackRate {
                        Label(Self.rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(Self.rateLabel(rate))
                    }
                }
            }
        } label: {
            PlaybackRatePillLabel(
                text: Self.rateLabel(playbackRate),
                isActive: playbackRate != 1.0,
                isEnabled: hasAudio,
                feedbackID: rateSelectionFeedbackID
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!hasAudio)
        .help("Playback speed")
    }

    private static func rateLabel(_ rate: Float) -> String {
        if rate == rate.rounded() {
            return "\(Int(rate))×"
        }
        return String(format: "%.1f×", rate)
    }

    private var playbackStatusTitle: String {
        if !hasAudio && !hasLocalSession {
            return "Audio not local yet"
        }
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if !hasAudio {
            return "Audio unavailable"
        }
        return sourceDescription
    }

    private var playbackStatusDetail: String {
        if !hasAudio && !hasLocalSession {
            return "Use Sync in the header"
        }
        if hasAudio && !isViewingLoadedAudio {
            return "Browsing another recording"
        }
        return "\(Self.timeText(currentTime)) / \(duration > 0 ? Self.timeText(duration) : "--:--")"
    }

    private var playbackStatusColor: Color {
        if errorMessage != nil && hasAudio {
            return DT.systemOrange
        }
        return Color.dtLabelSecondary
    }

    static func timeText(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct CloudNowPlayingMiniPane: View {
    let recording: CloudRecording
    let isPlaying: Bool
    let currentTime: Double
    let duration: Double
    let playbackRate: Float
    let onPlayPause: () -> Void
    let onSelectRate: (Float) -> Void
    let onSelectRecording: () -> Void

    @State private var rateSelectionFeedbackID = 0

    private static let rateOptions: [Float] = [0.5, 1.0, 1.5, 2.0, 3.0]

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(PanelIconButtonStyle(size: 24))
            .help(isPlaying ? "Pause" : "Play")

            Button(action: onSelectRecording) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(recording.presentationTitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.dtLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text("\(recording.sourceLine) · \(CloudMeetingPlaybackStrip.timeText(currentTime)) / \(duration > 0 ? CloudMeetingPlaybackStrip.timeText(duration) : "--:--")")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.dtLabelTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("Show playing recording")

            playbackRateMenu
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach(Self.rateOptions, id: \.self) { rate in
                Button {
                    onSelectRate(rate)
                    rateSelectionFeedbackID += 1
                } label: {
                    if rate == playbackRate {
                        Label(Self.rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(Self.rateLabel(rate))
                    }
                }
            }
        } label: {
            PlaybackRatePillLabel(
                text: Self.rateLabel(playbackRate),
                isActive: playbackRate != 1.0,
                isEnabled: true,
                feedbackID: rateSelectionFeedbackID
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed")
    }

    private static func rateLabel(_ rate: Float) -> String {
        if rate == rate.rounded() {
            return "\(Int(rate))×"
        }
        return String(format: "%.1f×", rate)
    }
}

struct MenuIconLabel: View {
    let systemName: String
    var size: CGFloat = 28

    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(hovered || pressed ? Color.dtLabel : Color.dtLabelSecondary)
            .background(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .fill(pressed ? Palette.controlFillPress : (hovered ? Palette.controlFillHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .strokeBorder(hovered || pressed ? Palette.borderHairline : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DT.R.control, style: .continuous))
            .onHover { hovered = $0 }
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(DT.motionAware(DT.ease(0.12)), value: hovered)
            .animation(DT.motionAware(DT.ease(0.08)), value: pressed)
            .onLongPressGesture(
                minimumDuration: .infinity,
                maximumDistance: 18,
                pressing: { pressed = $0 },
                perform: {}
            )
    }
}

struct PlaybackRatePillLabel: View {
    let text: String
    let isActive: Bool
    let isEnabled: Bool
    let feedbackID: Int

    @State private var hovered = false
    @State private var pressed = false
    @State private var didChange = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(foregroundColor)
            .frame(width: 40, height: 25)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovered = isEnabled && $0 }
            .scaleEffect(pressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(DT.motionAware(DT.ease(0.12)), value: hovered)
            .animation(DT.motionAware(DT.ease(0.08)), value: pressed)
            .animation(DT.motionAware(DT.ease(0.18)), value: isActive)
            .animation(DT.motionAware(DT.ease(0.16)), value: didChange)
            .onLongPressGesture(
                minimumDuration: .infinity,
                maximumDistance: 18,
                pressing: { isPressing in
                    pressed = isEnabled && isPressing
                },
                perform: {}
            )
            .onChange(of: text) { _, _ in
                guard isEnabled else { return }
                flashChange()
            }
            .onChange(of: feedbackID) { _, _ in
                guard isEnabled else { return }
                flashChange()
            }
    }

    private func flashChange() {
        didChange = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            didChange = false
        }
    }

    private var foregroundColor: Color {
        if !isEnabled { return Color.dtLabelTertiary }
        if isActive || didChange { return DT.waveformLit }
        return hovered ? Color.dtLabel : Color.dtLabel
    }

    private var fillColor: Color {
        if pressed {
            return Palette.controlFillPress
        }
        if didChange {
            return DT.waveformLit.opacity(0.24)
        }
        if isActive {
            return DT.waveformLit.opacity(hovered ? 0.20 : 0.14)
        }
        return hovered ? Palette.controlFillPress : Palette.controlFillHover
    }

    private var strokeColor: Color {
        if didChange {
            return DT.waveformLit.opacity(0.70)
        }
        if isActive {
            return DT.waveformLit.opacity(hovered ? 0.55 : 0.40)
        }
        return hovered ? Palette.borderStrong : Palette.borderSubtle
    }
}

struct CloudPlaybackWaveformScrubber: View {
    let progress: Double
    let isEnabled: Bool
    let peaks: [Float]
    let isLoadingPeaks: Bool
    var compact = false
    let onSeekProgress: (Double) -> Void

    private var trackHeight: CGFloat { compact ? 13 : 32 }
    private let horizontalInset: CGFloat = 7
    private var scrubberHeight: CGFloat { compact ? 18 : 44 }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, scrubberHeight)
            let inset = min(horizontalInset, max(width / 2 - 1, 0))
            let contentWidth = max(width - inset * 2, 1)
            let spacing: CGFloat = 2.4
            let barCount = Self.barCount(for: contentWidth)
            let barWidth = Self.barWidth(for: contentWidth, barCount: barCount, spacing: spacing)
            let timeline = WaveformTimeline(
                inset: inset,
                contentWidth: contentWidth,
                barWidth: barWidth
            )

            // Apple Music-style scrubber: progress is communicated
            // entirely by the played/unplayed bar colour split. No
            // overlay playhead — peng-xiao asked for the two black
            // handle dots gone.
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(barColor(index: index, count: barCount))
                        .frame(width: barWidth, height: barHeight(index: index, count: barCount))
                }
            }
            .frame(width: contentWidth, height: trackHeight, alignment: .center)
            .offset(x: inset)
            .opacity(isEnabled ? (isLoadingPeaks ? 0.58 : 1) : 0.46)
            .frame(width: width, height: height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        onSeekProgress(timeline.progress(for: value.location.x))
                    }
            )
        }
        .frame(height: scrubberHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
    }

    private static func barCount(for width: CGFloat) -> Int {
        max(18, min(128, Int(width / 5.2)))
    }

    private static func barWidth(for width: CGFloat, barCount: Int, spacing: CGFloat) -> CGFloat {
        let availableWidth = width - spacing * CGFloat(max(barCount - 1, 0))
        return max(1.8, availableWidth / CGFloat(max(barCount, 1)))
    }

    private struct WaveformTimeline {
        let inset: CGFloat
        let contentWidth: CGFloat
        let barWidth: CGFloat

        private var startX: CGFloat {
            inset + barWidth / 2
        }

        private var width: CGFloat {
            max(contentWidth - barWidth, 1)
        }

        func xPosition(for progress: Double) -> CGFloat {
            startX + width * CGFloat(min(max(progress, 0), 1))
        }

        func progress(for xPosition: CGFloat) -> Double {
            Double(min(max((xPosition - startX) / width, 0), 1))
        }

        static func isBarPlayed(index: Int, count: Int, progress: Double) -> Bool {
            guard count > 1 else { return progress >= 0.5 }
            let clampedProgress = min(max(progress, 0), 1)
            let barProgress = Double(index) / Double(count - 1)
            return barProgress <= clampedProgress
        }
    }

    private func barColor(index: Int, count: Int) -> Color {
        if WaveformTimeline.isBarPlayed(index: index, count: count, progress: progress) {
            return DT.waveformLit.opacity(isEnabled ? 0.92 : 0.42)
        }
        return isEnabled ? Palette.labelTertiary : Palette.labelQuaternary
    }

    private func barHeight(index: Int, count: Int) -> CGFloat {
        let normalizedPeak = peakValue(index: index, count: count)
        let height = 5 + (trackHeight - 5) * CGFloat(normalizedPeak)
        return max(5, min(trackHeight, height))
    }

    private func peakValue(index: Int, count: Int) -> Float {
        guard !peaks.isEmpty else {
            return isLoadingPeaks ? 0.18 : 0.08
        }

        guard peaks.count > 1, count > 1 else {
            return min(max(peaks.first ?? 0, 0), 1)
        }

        let sourcePosition = Double(index) * Double(peaks.count - 1) / Double(count - 1)
        let lowerIndex = min(max(Int(sourcePosition.rounded(.down)), 0), peaks.count - 1)
        let upperIndex = min(lowerIndex + 1, peaks.count - 1)
        let fraction = Float(sourcePosition - Double(lowerIndex))
        let lower = min(max(peaks[lowerIndex], 0), 1)
        let upper = min(max(peaks[upperIndex], 0), 1)
        return lower + ((upper - lower) * fraction)
    }
}
