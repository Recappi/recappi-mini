import SwiftUI

struct ErrorState: View {
    @ObservedObject var recorder: AudioRecorder
    let message: String
    var onShow: () -> Void
    var onSettings: () -> Void
    var onRetry: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DT.systemOrange)
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
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
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
                Button("Show", action: onShow).buttonStyle(PanelPushButtonStyle())
                    .accessibilityIdentifier(AccessibilityIDs.Panel.showButton)
                if isConfigRelated {
                    Button("Settings…", action: onSettings).buttonStyle(PanelPushButtonStyle())
                        .accessibilityIdentifier(AccessibilityIDs.Panel.settingsButton)
                }
                Button("Retry", action: onRetry).buttonStyle(PanelPushButtonStyle(primary: true))
                    .accessibilityIdentifier(AccessibilityIDs.Panel.retryButton)
            }
        } else if isConfigRelated {
            HStack(spacing: 6) {
                Button("Settings…", action: onSettings).buttonStyle(PanelPushButtonStyle(primary: true))
                    .accessibilityIdentifier(AccessibilityIDs.Panel.settingsButton)
            }
        }
    }

    private var title: String {
        recorder.lastSessionDir != nil ? "Processing failed" : "Recording failed"
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
