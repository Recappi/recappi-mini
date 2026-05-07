import SwiftUI

struct DoneState: View {
    let result: RecordingResult
    var onShow: () -> Void
    var onCopy: () -> Void
    var onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.9))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(DT.waveformLit))
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))

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

            HStack(spacing: 8) {
                Button("Show", action: onShow).buttonStyle(PanelPushButtonStyle())
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(AccessibilityIDs.Panel.showButton)
                Button("Copy", action: onCopy).buttonStyle(PanelPushButtonStyle())
                    .frame(maxWidth: .infinity)
                Button("Done", action: onNew).buttonStyle(PanelPushButtonStyle(primary: true))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
