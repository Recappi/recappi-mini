import SwiftUI

struct DoneState: View {
    private enum Metrics {
        static let iconSize: CGFloat = 16
        static let iconGap: CGFloat = 7
        static let actionHeight: CGFloat = 22
    }

    let result: RecordingResult
    var canTranscribe: Bool = false
    /// Per-recording cloud lifecycle. `nil` collapses the status pill
    /// (e.g. when the cloud / auto-transcribe feature flag is off). The
    /// resolver lives in RecordingPanel; this view never derives it.
    var cloudStatus: DoneCloudStatus? = nil
    var onTranscribe: () -> Void = {}
    var onShow: () -> Void
    var onNew: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            // Leading slot — when a cloud status is present, its
            // per-state icon carries the visual signal (uploading arrow /
            // hourglass / waveform / etc.) so the static ✓ would just
            // duplicate. When status is `nil` (cloud disabled / flag-off)
            // we fall back to a single ✓ so the toast still reads "done".
            if let status = cloudStatus {
                Image(systemName: status.displayIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolEffect(.pulse, options: .repeating, isActive: status.isActive)
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(statusColor(status))
                    .frame(width: Metrics.iconSize, height: Metrics.iconSize)
                    .accessibilityIdentifier(AccessibilityIDs.Panel.doneTitle)
                    .accessibilityLabel("Meeting saved · \(status.displayText)")

                Text(status.displayText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(statusColor(status))
                    .contentTransition(.opacity)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                separator
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DT.statusReady)
                    .frame(width: Metrics.iconSize, height: Metrics.iconSize)
                    .accessibilityIdentifier(AccessibilityIDs.Panel.doneTitle)
                    .accessibilityLabel("Meeting saved")
            }

            Text(formatTime(result.duration))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                // Bumped tertiary→secondary: at 0.38 alpha the time washed out
                // on the translucent panel over a busy backdrop (peng-xiao 6/4).
                .foregroundStyle(Color.dtLabelSecondary)

            Spacer(minLength: 10)

            primaryActionChip

            trailingQuietLink(
                title: "Dismiss",
                help: "Close this notification. The recording stays in Recappi Cloud.",
                action: onNew
            )
        }
        .frame(height: Metrics.actionHeight)
        .padding(.leading, 2)
        .animation(.smooth(duration: 0.28), value: cloudStatus)
    }

    private func statusColor(_ status: DoneCloudStatus) -> Color {
        switch status {
        case .ready, .synced:
            return DT.statusReady
        case .syncFailed, .transcriptionFailed:
            return Color(red: 0.95, green: 0.46, blue: 0.32)
        case .savedLocally, .uploading, .pending, .queued, .transcribing:
            return Color.dtLabelSecondary
        }
    }

    private var separator: some View {
        Text("·")
            .font(.system(size: 11))
            .foregroundStyle(Color.dtLabelTertiary)
    }

    private var primaryActionChip: some View {
        Button(action: canTranscribe ? onTranscribe : onShow) {
            HStack(spacing: 5) {
                Text(canTranscribe ? "Transcribe" : "View")
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
        .recappiTooltip(canTranscribe ? "Start cloud transcription and open Recappi Cloud" : "Open this recording in Recappi Cloud")
        .accessibilityIdentifier(canTranscribe ? AccessibilityIDs.Panel.transcribeButton : AccessibilityIDs.Panel.showButton)
    }

    private func trailingQuietLink(title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                // Bumped secondary→primary so "Dismiss" stays legible on the
                // translucent panel over a busy backdrop (peng-xiao 6/4).
                .foregroundStyle(Palette.labelPrimary)
                .padding(.horizontal, 4)
                .frame(height: Metrics.actionHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .recappiTooltip(help)
    }

    private func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// Icon + copy mapping live with the view, not on the shared model.
// Per @Mini's boundary lock: shared `DoneCloudStatus` carries state truth
// (cases + `isActive`); choosing the SF Symbol and the user-facing label
// is visual strategy and changes on style iteration alone.
private extension DoneCloudStatus {
    var displayText: String {
        switch self {
        case .savedLocally: return "Local"
        case .uploading: return "Uploading"
        case .synced: return "Synced"
        case .pending: return "Pending"
        case .queued: return "Queued"
        case .transcribing: return "Transcribing"
        case .ready: return "Ready"
        case .syncFailed: return "Sync failed"
        case .transcriptionFailed: return "Failed"
        }
    }

    var displayIcon: String {
        switch self {
        case .savedLocally: return "internaldrive"
        case .uploading: return "arrow.up.circle"
        case .synced: return "checkmark.circle.fill"
        case .pending: return "hourglass"
        case .queued: return "clock.arrow.circlepath"
        case .transcribing: return "waveform"
        case .ready: return "checkmark.circle.fill"
        case .syncFailed, .transcriptionFailed: return "exclamationmark.triangle.fill"
        }
    }
}
