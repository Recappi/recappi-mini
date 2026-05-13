import SwiftUI

struct DoneState: View {
    let result: RecordingResult
    var canTranscribe: Bool = false
    var onTranscribe: () -> Void = {}
    var onShow: () -> Void
    var onCopy: () -> Void
    var onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("🎉")
                    .font(.system(size: 14))
                    .frame(width: 16, height: 16)

                Text("Meeting saved")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)
                    .accessibilityIdentifier(AccessibilityIDs.Panel.doneTitle)

                Spacer(minLength: 0)

                Text(formatTime(result.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.dtLabelSecondary)
            }

            primaryActionButton

            HStack(spacing: 12) {
                secondaryActionButton(
                    title: "View recording",
                    systemImage: "rectangle.stack",
                    action: onShow
                )
                .accessibilityIdentifier(AccessibilityIDs.Panel.showButton)

                if hasTranscript {
                    secondaryActionButton(
                        title: "Copy",
                        systemImage: "doc.on.doc",
                        action: onCopy
                    )
                }

                Spacer(minLength: 0)

                secondaryActionButton(
                    title: "Done",
                    systemImage: "checkmark",
                    action: onNew
                )
            }
            .frame(height: 22)
        }
    }

    private var primaryActionButton: some View {
        Button(action: canTranscribe ? onTranscribe : onShow) {
            HStack(spacing: 8) {
                Image(systemName: canTranscribe ? "waveform.badge.magnifyingglass" : "rectangle.stack")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(canTranscribe ? "Transcribe in Cloud" : "View in Cloud")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10.5, weight: .bold))
            }
        }
        .buttonStyle(PanelPushButtonStyle(primary: true))
        .help(canTranscribe ? "Start cloud transcription and open Recappi Cloud" : "Open this recording in Recappi Cloud")
        .accessibilityIdentifier(canTranscribe ? AccessibilityIDs.Panel.transcribeButton : AccessibilityIDs.Panel.showButton)
    }

    private func secondaryActionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.dtLabelSecondary)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private var hasTranscript: Bool {
        result.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
