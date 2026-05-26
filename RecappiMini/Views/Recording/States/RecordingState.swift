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
                    .shadow(color: DT.recordingLiveBlue.opacity(0.6), radius: 2)
                    .modifier(PulsingModifier())
                Text(formatTime(recorder.elapsedSeconds))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Palette.labelPrimary)
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.labelTertiary)
                recordingSourceView
                Spacer(minLength: 0)
                if appDelegate.canShowLiveCaptionPanel {
                    Button {
                        appDelegate.setLiveCaptionPanelPresented(!appDelegate.isLiveCaptionPanelPresented)
                    } label: {
                        Image(systemName: appDelegate.isLiveCaptionPanelPresented ? "captions.bubble.fill" : "captions.bubble")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(PanelIconButtonStyle(size: 18))
                    .help(appDelegate.isLiveCaptionPanelPresented ? "Hide live captions" : "Show live captions")
                    .accessibilityIdentifier(AccessibilityIDs.Panel.liveCaptionsButton)
                }
                Button(action: onClose) {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(PanelIconButtonStyle(size: 14))
                .help("Hide panel")
                .accessibilityIdentifier(AccessibilityIDs.Panel.closeButton)
            }
            .padding(.horizontal, 2)

            controlsRow
                .frame(height: 28)
        }
    }

    @ViewBuilder
    private var controlsRow: some View {
        if isConfirmingDiscard {
            discardConfirmationRow
        } else {
            recordingControlsRow
        }
    }

    private var recordingControlsRow: some View {
        HStack(spacing: 6) {
            Button(action: handleWaveformTap) {
                waveformView
                    .frame(maxWidth: .infinity, maxHeight: 28)
                    .padding(.leading, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(waveformHelpText)
            .accessibilityIdentifier(AccessibilityIDs.Panel.waveformToggle)

            microphoneButton

            moreMenu

            PrimaryRecordButton(kind: .stop, action: onStop)
                .keyboardShortcut(.return, modifiers: [])
                .help("Stop")
                .accessibilityIdentifier(AccessibilityIDs.Panel.stopButton)
        }
    }

    private var discardConfirmationRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DT.recordingDestructiveRed)
                .frame(width: 18, height: 28)

            Text("Discard recording?")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.labelPrimary)
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

            Button("Discard") {
                isConfirmingDiscard = false
                onDiscard()
            }
            .buttonStyle(RecordingInlineConfirmButtonStyle(destructive: true))
            .accessibilityIdentifier(AccessibilityIDs.Panel.discardButton)

            PrimaryRecordButton(kind: .stop, action: onStop)
                .keyboardShortcut(.return, modifiers: [])
                .help("Stop")
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
                    .fill(recordingGlassControlFill)
                    .glassEffect(.regular.tint(recordingGlassControlTint), in: controlShape)
                    .overlay(
                        controlShape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(isDarkMode ? 0.10 : 0.22),
                                        Color.clear,
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .blendMode(.screen)
                    )
                    .overlay(
                        controlShape
                            .strokeBorder(Color.white.opacity(isDarkMode ? 0.12 : 0.28), lineWidth: 0.5)
                    )
                    .frame(width: 28, height: 28)

                Image(systemName: recorder.includesMicrophoneAudio ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(
                        recorder.includesMicrophoneAudio
                            ? DT.recordingLiveBlue
                            : Palette.labelTertiary
                    )
                    .frame(width: 28, height: 28)

                if recorder.includesMicrophoneAudio {
                    Circle()
                        .fill(DT.recordingLiveBlue)
                        .frame(width: 5.5, height: 5.5)
                        .overlay(
                            Circle()
                                .stroke(Palette.surfacePanel, lineWidth: 1)
                        )
                        .offset(x: 3, y: -2.5)
                        .modifier(PulsingModifier())
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(recorder.includesMicrophoneAudio ? "Microphone on (click to mute)" : "Microphone muted (click to unmute)")
        .accessibilityIdentifier(AccessibilityIDs.Panel.microphoneIncludeButton)
    }

    private var controlShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
    }

    private var recordingGlassControlFill: Color {
        isDarkMode ? Color.black.opacity(0.16) : Color.white.opacity(0.15)
    }

    private var recordingGlassControlTint: Color {
        isDarkMode ? DT.appAccent.opacity(0.12) : DT.appAccentSoft.opacity(0.16)
    }

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    @ViewBuilder
    private var waveformView: some View {
        switch waveformMode {
        case .spectrum:
            DotMatrixWaveform(levels: recorder.audioSpectrumLevels)
        case .history:
            DotMatrixWaveform(levels: recorder.audioLevelHistory)
        }
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
        .help("More recording actions")
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
                .foregroundStyle(Palette.labelSecondary)
                .lineLimit(1)
        }
        .help(recordingSourceIcon == nil ? "Recording all system audio" : "Recording \(recordingSourceLabel)")
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

    private func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
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
                .foregroundStyle(destructive ? DT.recordingDestructiveRed : Palette.labelPrimary)
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
