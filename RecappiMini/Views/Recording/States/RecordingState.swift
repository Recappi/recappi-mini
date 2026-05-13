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
    @AppStorage("recappi.panel.recordingWaveformMode") private var waveformModeRaw = WaveformMode.spectrum.rawValue
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
                    .fill(DT.systemRed)
                    .frame(width: 6, height: 6)
                    .shadow(color: DT.systemRed.opacity(0.6), radius: 2)
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

                Button {
                    recorder.setIncludesMicrophoneAudio(!recorder.includesMicrophoneAudio)
                } label: {
                    Image(systemName: recorder.includesMicrophoneAudio ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(PanelIconButtonStyle())
                .help(recorder.includesMicrophoneAudio ? "Microphone on (click to mute)" : "Microphone muted (click to unmute)")
                .accessibilityIdentifier(AccessibilityIDs.Panel.microphoneIncludeButton)

                Button(action: onDiscard) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(PanelIconButtonStyle())
                .help("Discard")
                .accessibilityIdentifier(AccessibilityIDs.Panel.discardButton)

                PrimaryRecordButton(kind: .stop, action: onStop)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Stop")
                    .accessibilityIdentifier(AccessibilityIDs.Panel.stopButton)
            }
            .frame(height: 28)
        }
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
                        .fill(DT.waveformLit)
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
