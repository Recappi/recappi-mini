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
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DT.statusReady)
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Meeting saved")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.dtLabel)
                        .accessibilityIdentifier(AccessibilityIDs.Panel.doneTitle)
                    Text(statusSubtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.dtLabelTertiary)
                }

                Spacer(minLength: 0)

                Text(formatTime(result.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.dtLabelSecondary)
            }

            HStack(spacing: 8) {
                primaryActionChip

                if hasTranscript {
                    quietLink(title: "Copy", action: onCopy)
                }

                Spacer(minLength: 0)

                quietLink(title: "Dismiss", action: onNew)
            }
        }
    }

    private var statusSubtitle: String {
        canTranscribe
            ? "Uploaded to Cloud · transcript pending"
            : "Ready in Recappi Cloud"
    }

    private var primaryActionChip: some View {
        Button(action: canTranscribe ? onTranscribe : onShow) {
            HStack(spacing: 5) {
                Text(canTranscribe ? "Transcribe in Cloud" : "View in Cloud")
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(DT.statusReady)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(
                Capsule(style: .continuous)
                    .fill(DT.statusReady.opacity(0.12))
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(canTranscribe ? "Start cloud transcription and open Recappi Cloud" : "Open this recording in Recappi Cloud")
        .accessibilityIdentifier(canTranscribe ? AccessibilityIDs.Panel.transcribeButton : AccessibilityIDs.Panel.showButton)
    }

    private func quietLink(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.dtLabelSecondary)
                .padding(.horizontal, 4)
                .frame(height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
