import SwiftUI

struct DoneState: View {
    private enum Metrics {
        static let iconSize: CGFloat = 16
        static let iconGap: CGFloat = 7
        static let actionHeight: CGFloat = 22
        static let leadingActionInset = iconSize + iconGap
        static let trailingColumnWidth: CGFloat = 58
    }

    let result: RecordingResult
    var canTranscribe: Bool = false
    var onTranscribe: () -> Void = {}
    var onShow: () -> Void
    var onCopy: () -> Void
    var onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Metrics.iconGap) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DT.statusReady)
                    .frame(width: Metrics.iconSize, height: Metrics.iconSize)

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
                    .frame(width: Metrics.trailingColumnWidth, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Color.clear
                    .frame(width: Metrics.leadingActionInset, height: Metrics.actionHeight)

                primaryActionChip

                if hasTranscript {
                    quietLink(title: "Copy", action: onCopy)
                }

                Spacer(minLength: 0)

                trailingQuietLink(title: "Dismiss", action: onNew)
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
            .frame(height: Metrics.actionHeight)
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
                .frame(height: Metrics.actionHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func trailingQuietLink(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.dtLabelSecondary)
                .frame(width: Metrics.trailingColumnWidth, height: Metrics.actionHeight, alignment: .trailing)
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
