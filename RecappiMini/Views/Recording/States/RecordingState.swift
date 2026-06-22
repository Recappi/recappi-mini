import AppKit
import SwiftUI

struct RecordingState: View {
    private enum WaveformMode: String {
        case spectrum
        case history

        var next: Self { self == .spectrum ? .history : .spectrum }
        var helpText: String {
            switch self {
            case .spectrum:
                return "Click to switch to slow scrolling volume history"
            case .history:
                return "Click to switch back to frequency buckets"
            }
        }
    }

    @ObservedObject var recorder: AudioRecorder
    @ObservedObject private var appDelegate = AppDelegate.shared
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("recappi.panel.recordingWaveformMode") private var waveformModeRaw = WaveformMode.spectrum.rawValue
    @State private var isConfirmingDiscard = false
    var autoStopRequest: AutoStopRecordingRequest?
    var onKeepRecording: () -> Void
    var onConfirmAutoStop: () -> Void
    var onDiscard: () -> Void
    var onStop: () -> Void
    var onClose: () -> Void

    var body: some View {
        // Caption (red dot + timer + source) sits above the main control row.
        // Same glass shell wraps the whole thing, but the caption is styled
        // as a subtle header so the pill row can carry the main visual
        // weight (logo tile + dot-matrix waveform + controls).
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(DT.recordingLiveBlue)
                    .frame(width: 6, height: 6)
                    .shadow(color: DT.recordingLiveBlue.opacity(minimalRecordingUI ? 0 : 0.6), radius: minimalRecordingUI ? 0 : 2)
                    .modifier(ConditionalPulsingModifier(isEnabled: !minimalRecordingUI))
                if minimalRecordingUI {
                    Text("Recording")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DT.recordingGlassTextPrimary)
                } else {
                    RecordingElapsedText(runtimeState: recorder.runtimeState)
                }
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(DT.recordingGlassTextTertiary)
                recordingSourceView
                Spacer(minLength: 0)
                if !minimalRecordingUI, appDelegate.canShowLiveCaptionPanel {
                    Button {
                        appDelegate.setLiveCaptionPanelPresented(!appDelegate.isLiveCaptionPanelPresented)
                    } label: {
                        Image(systemName: appDelegate.isLiveCaptionPanelPresented ? "captions.bubble.fill" : "captions.bubble")
                            .font(.system(size: 10.5, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .animation(DT.motionAware(DT.ease(0.16)), value: appDelegate.isLiveCaptionPanelPresented)
                    }
                    .buttonStyle(PanelIconButtonStyle(size: 18))
                    .recappiTooltip(appDelegate.isLiveCaptionPanelPresented ? "Hide live captions" : "Show live captions")
                    .accessibilityIdentifier(AccessibilityIDs.Panel.liveCaptionsButton)
                }
                Button(action: onClose) {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(PanelIconButtonStyle(size: 14, backdropAdaptiveForeground: true))
                .recappiTooltip("Hide panel · recording continues in the background")
                .accessibilityIdentifier(AccessibilityIDs.Panel.closeButton)
            }
            .padding(.horizontal, 2)

            controlsRow
                .frame(height: 28)
        }
    }

    @ViewBuilder
    private var controlsRow: some View {
        if let autoStopRequest {
            autoStopConfirmationRow(request: autoStopRequest)
        } else if isConfirmingDiscard {
            discardConfirmationRow
        } else {
            recordingControlsRow
        }
    }

    private var recordingControlsRow: some View {
        HStack(spacing: 6) {
            if minimalRecordingUI {
                minimalRecordingUIIndicator
                    .frame(maxWidth: .infinity, maxHeight: 28)
                    .padding(.leading, 4)
            } else {
                Button(action: handleWaveformTap) {
                    waveformView
                        .frame(maxWidth: .infinity, maxHeight: 28)
                        .padding(.leading, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .recappiTooltip(waveformHelpText)
                .accessibilityIdentifier(AccessibilityIDs.Panel.waveformToggle)
            }

            microphoneButton

            moreMenu

            PrimaryRecordButton(kind: .stop, action: onStop)
                .keyboardShortcut(.return, modifiers: [])
                .recappiTooltip("Stop recording and start processing (⏎)")
                .accessibilityIdentifier(AccessibilityIDs.Panel.stopButton)
        }
    }

    private func autoStopConfirmationRow(request: AutoStopRecordingRequest) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "video.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DT.recordingLiveBlue)
                .frame(width: 18, height: 28)

            Text("Meeting ended?")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(DT.recordingGlassTextPrimary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 0)

            Button("Keep") {
                onKeepRecording()
            }
            .buttonStyle(RecordingInlineConfirmButtonStyle())
            .keyboardShortcut(.cancelAction)
            .recappiTooltip("Keep recording even though \(request.context.promptTitle) is no longer detected")
            .accessibilityIdentifier(AccessibilityIDs.Panel.autoStopKeepButton)

            Button("Stop") {
                onConfirmAutoStop()
            }
            .buttonStyle(RecordingInlineConfirmButtonStyle(destructive: true))
            .keyboardShortcut(.return, modifiers: [])
            .recappiTooltip("Stop recording and start processing")
            .accessibilityIdentifier(AccessibilityIDs.Panel.autoStopStopButton)
        }
        .accessibilityIdentifier(AccessibilityIDs.Panel.autoStopPrompt)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var discardConfirmationRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DT.recordingDestructiveRed)
                .frame(width: 18, height: 28)

            Text("Discard recording?")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(DT.recordingGlassTextPrimary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 0)

            Button("Cancel") {
                withAnimation(DT.motionAware(DT.ease(DT.Motion.elementPresence))) {
                    isConfirmingDiscard = false
                }
            }
            .buttonStyle(RecordingInlineConfirmButtonStyle())
            .keyboardShortcut(.cancelAction)
            .recappiTooltip("Keep recording")

            Button("Discard") {
                isConfirmingDiscard = false
                onDiscard()
            }
            .buttonStyle(RecordingInlineConfirmButtonStyle(destructive: true))
            .recappiTooltip("Permanently delete this recording without saving")
            .accessibilityIdentifier(AccessibilityIDs.Panel.discardButton)

            PrimaryRecordButton(kind: .stop, action: onStop)
                .keyboardShortcut(.return, modifiers: [])
                .recappiTooltip("Stop recording and start processing (⏎)")
                .accessibilityIdentifier(AccessibilityIDs.Panel.stopButton)
        }
        .transition(.opacity)
    }

    private var microphoneButton: some View {
        Button {
            recorder.setIncludesMicrophoneAudio(!recorder.includesMicrophoneAudio)
        } label: {
            ZStack(alignment: .topTrailing) {
                controlShape
                    .fill(microphoneControlFill)
                    .overlay(
                        controlShape
                            .strokeBorder(microphoneControlStroke, lineWidth: 0.5)
                    )
                    .frame(width: 28, height: 28)

                Image(systemName: recorder.includesMicrophoneAudio ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 12))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(
                        recorder.includesMicrophoneAudio
                            ? DT.recordingLiveBlue
                            : DT.recordingGlassTextTertiary
                    )
                    .frame(width: 28, height: 28)
                    .animation(DT.motionAware(DT.ease(0.16)), value: recorder.includesMicrophoneAudio)

                if recorder.includesMicrophoneAudio, !minimalRecordingUI {
                    Circle()
                        .fill(DT.recordingLiveBlue)
                        .frame(width: 5.5, height: 5.5)
                        .overlay(
                            Circle()
                                .stroke(Palette.surfacePanel, lineWidth: 1)
                        )
                        .offset(x: 3, y: -2.5)
                        .modifier(PulsingModifier())
                        .transition(.scale(scale: 0.72).combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .animation(DT.motionAware(DT.ease(0.14)), value: recorder.includesMicrophoneAudio)
        }
        .buttonStyle(.plain)
        .recappiTooltip(recorder.includesMicrophoneAudio ? "Microphone on (click to mute)" : "Microphone muted (click to unmute)")
        .accessibilityIdentifier(AccessibilityIDs.Panel.microphoneIncludeButton)
    }

    private var controlShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
    }

    private var microphoneControlFill: Color {
        if recorder.includesMicrophoneAudio {
            return DT.recordingLiveBlue.opacity(isDarkMode ? 0.12 : 0.07)
        }
        return Color.dtLabel.opacity(isDarkMode ? 0.07 : 0.035)
    }

    private var microphoneControlStroke: Color {
        if recorder.includesMicrophoneAudio {
            return DT.recordingLiveBlue.opacity(isDarkMode ? 0.22 : 0.16)
        }
        return Palette.borderHairline.opacity(0.6)
    }

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    private var minimalRecordingUI: Bool {
        RecappiPerformanceDebugOptions.minimalRecordingUI()
    }

    private var minimalRecordingUIIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DT.recordingGlassTextSecondary)
            Text("Minimal UI")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DT.recordingGlassTextSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityLabel("Minimal recording UI debug mode")
    }

    @ViewBuilder
    private var waveformView: some View {
        RecordingWaveformView(runtimeState: recorder.runtimeState, mode: waveformMode)
    }

    private var moreMenu: some View {
        Menu {
            Button(role: .destructive) {
                isConfirmingDiscard = true
            } label: {
                Label("Discard recording", systemImage: "trash")
            }
            .accessibilityIdentifier(AccessibilityIDs.Panel.discardMenuItem)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: DT.R.control, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .recappiTooltip("More recording actions")
        .accessibilityLabel("More recording actions")
        .accessibilityIdentifier(AccessibilityIDs.Panel.recordingMoreButton)
    }

    private var recordingSourceLabel: String {
        recorder.recordingAppName ?? recorder.selectedApp?.name ?? "All system audio"
    }

    @ViewBuilder
    private var recordingSourceView: some View {
        HStack(spacing: 4) {
            if let icon = recordingSourceIcon {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 12, height: 12)
                        .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                    Circle()
                        .fill(DT.recordingLiveBlue)
                        .frame(width: 4.5, height: 4.5)
                        .overlay(
                            Circle()
                                .stroke(Palette.surfacePanel, lineWidth: 1)
                        )
                        .offset(x: 1.5, y: 1.5)
                }
                .frame(width: 14, height: 12)
                .accessibilityHidden(true)
            }

            Text(recordingSourceLabel)
                .font(.system(size: 11))
                .foregroundStyle(DT.recordingGlassTextSecondary)
                .lineLimit(1)
        }
        .recappiTooltip(recordingSourceIcon == nil ? "Recording all system audio" : "Recording \(recordingSourceLabel)")
    }

    private var recordingSourceIcon: NSImage? {
        recorder.selectedApp?.icon
    }

    private var waveformHelpText: String {
        guard recorder.selectedApp != nil else { return waveformMode.helpText }
        return "Bring \(recordingSourceLabel) to front"
    }

    private var waveformMode: WaveformMode {
        get { WaveformMode(rawValue: waveformModeRaw) ?? .spectrum }
        nonmutating set { waveformModeRaw = newValue.rawValue }
    }

    private func toggleWaveformMode() {
        waveformMode = waveformMode.next
    }

    private func handleWaveformTap() {
        if recorder.focusRecordingSourceIfAvailable() { return }
        toggleWaveformMode()
    }

    private struct RecordingElapsedText: View {
        @ObservedObject var runtimeState: RecordingRuntimeState

        var body: some View {
            Text(formatTime(runtimeState.elapsedSeconds))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(DT.recordingGlassTextPrimary)
        }

        private func formatTime(_ seconds: Int) -> String {
            let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
            if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
            return String(format: "%02d:%02d", m, s)
        }
    }

    private struct RecordingWaveformView: View {
        @ObservedObject var runtimeState: RecordingRuntimeState
        let mode: WaveformMode

        var body: some View {
            switch mode {
            case .spectrum:
                DotMatrixWaveform(levels: runtimeState.audioSpectrumLevels)
            case .history:
                DotMatrixWaveform(levels: runtimeState.audioLevelHistory)
            }
        }
    }
}

private struct ConditionalPulsingModifier: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.modifier(PulsingModifier())
        } else {
            content
        }
    }
}

private struct RecordingInlineConfirmButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        Chrome(
            isPressed: configuration.isPressed,
            destructive: destructive,
            label: configuration.label
        )
    }

    private struct Chrome<Label: View>: View {
        let isPressed: Bool
        let destructive: Bool
        let label: Label
        @State private var hovered = false

        var body: some View {
            label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(destructive ? DT.recordingDestructiveRed : DT.recordingGlassTextPrimary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                        .fill(backgroundFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: destructive ? 0.8 : 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: DT.R.control, style: .continuous))
                .scaleEffect(isPressed ? 0.98 : 1)
                .onHover { hovered = $0 }
                .animation(DT.motionAware(DT.ease(0.12)), value: hovered)
                .animation(DT.motionAware(DT.ease(0.08)), value: isPressed)
        }

        private var backgroundFill: Color {
            if destructive {
                return DT.recordingDestructiveRed.opacity(isPressed ? 0.16 : (hovered ? 0.12 : 0.07))
            }
            return isPressed ? Palette.controlFillPress : (hovered ? Palette.controlFillHover : Palette.surfaceChip.opacity(0.55))
        }

        private var borderColor: Color {
            destructive ? DT.recordingDestructiveRed.opacity(hovered || isPressed ? 0.36 : 0.22) : Palette.borderHairline
        }
    }
}
