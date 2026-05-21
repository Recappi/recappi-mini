import SwiftUI

struct ErrorState: View {
    @ObservedObject var recorder: AudioRecorder
    let message: String
    var onShow: () -> Void
    var onSettings: () -> Void
    var onOpenLogs: () -> Void
    var onRetry: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DT.recordingErrorAmber)
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.dtLabel)
                        .accessibilityIdentifier(AccessibilityIDs.Panel.errorTitle)
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.dtLabelSecondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if let technicalDetails {
                        Text(technicalDetails)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.dtLabelTertiary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.dtLabel.opacity(0.035))
                            )
                            .padding(.top, 3)
                    }
                }

                Spacer(minLength: 0)

                // Dismiss — the only way back to idle when retry isn't an
                // option and the user just wants to close the panel's error
                // state without opening Settings.
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(PanelIconButtonStyle(size: 22))
                .help("Dismiss")
            }

            actionsRow
        }
    }

    @ViewBuilder
    private var actionsRow: some View {
        if recorder.lastSessionDir != nil {
            HStack(spacing: 6) {
                if isRetryable {
                    Button("Retry", action: onRetry)
                        .buttonStyle(ErrorRetryButtonStyle())
                        .accessibilityIdentifier(AccessibilityIDs.Panel.retryButton)
                    moreMenu
                } else {
                    Button("Show in Finder", action: onShow)
                        .buttonStyle(PanelPushButtonStyle())
                        .accessibilityIdentifier(AccessibilityIDs.Panel.showButton)
                    Button("Open Logs", action: onOpenLogs)
                        .buttonStyle(PanelPushButtonStyle())
                        .accessibilityIdentifier(AccessibilityIDs.Panel.openLogsButton)
                }
            }
        } else if isConfigRelated {
            HStack(spacing: 6) {
                Button("Settings…", action: onSettings)
                    .buttonStyle(ErrorRetryButtonStyle())
                    .accessibilityIdentifier(AccessibilityIDs.Panel.settingsButton)
                Button("Open Logs", action: onOpenLogs)
                    .buttonStyle(PanelPushButtonStyle())
                    .accessibilityIdentifier(AccessibilityIDs.Panel.openLogsButton)
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Show in Finder", action: onShow)
                .accessibilityIdentifier(AccessibilityIDs.Panel.showButton)
            if isConfigRelated {
                Button("Settings…", action: onSettings)
                    .accessibilityIdentifier(AccessibilityIDs.Panel.settingsButton)
            }
            Button("Open Logs", action: onOpenLogs)
                .accessibilityIdentifier(AccessibilityIDs.Panel.openLogsButton)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(PanelPushButtonStyle())
        .help("More recovery actions")
    }

    private var title: String {
        if isMissingCapturedAudio {
            return "Recording failed"
        }
        return recorder.lastSessionDir != nil ? "Processing failed" : "Recording failed"
    }

    private var isRetryable: Bool {
        !isMissingCapturedAudio
    }

    private var technicalDetails: String? {
        guard isMissingCapturedAudio else { return nil }
        guard let sessionDir = recorder.lastSessionDir else {
            return "capture=no-audio\nrecording.m4a=missing"
        }
        let recordingURL = RecordingStore.audioFileURL(in: sessionDir)
        let systemURL = sessionDir.appendingPathComponent("system.caf")
        let micURL = sessionDir.appendingPathComponent("mic.caf")
        return [
            "session=\(sessionDir.lastPathComponent)",
            "recording.m4a=\(fileDetail(recordingURL))",
            "system.caf=\(fileDetail(systemURL)) mic.caf=\(fileDetail(micURL))",
        ].joined(separator: "\n")
    }

    private func fileDetail(_ url: URL) -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return "missing" }
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? -1
        return size >= 0 ? "\(size)b" : "exists"
    }

    private var isMissingCapturedAudio: Bool {
        let lower = message.lowercased()
        return lower.contains("no audio was captured")
            || lower.contains("recorded audio is missing")
            || lower.contains("meeting app was closed")
    }

    private var isConfigRelated: Bool {
        let lower = message.lowercased()
        return lower.contains("api")
            || lower.contains("key")
            || lower.contains("auth")
            || lower.contains("oauth")
            || lower.contains("token")
            || lower.contains("bearer")
            || lower.contains("session")
            || lower.contains("sign in")
            || lower.contains("language not supported")
    }
}

private struct ErrorRetryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.88))
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .fill(DT.recordingErrorAmber)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}
