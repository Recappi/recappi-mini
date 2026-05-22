import SwiftUI

struct PermissionsSettingsPage: View {
    @Binding var snapshot: CapturePermissionSnapshot
    @Binding var permissionsBusy: Bool
    let onRefresh: () -> Void

    var body: some View {
        Form {
            Section {
                permissionRow(
                    title: "Microphone",
                    state: snapshot.microphone,
                    statusID: AccessibilityIDs.Settings.permissionMicrophoneStatus,
                    requestID: AccessibilityIDs.Settings.requestMicrophoneButton,
                    action: requestMicrophonePermission
                )

                permissionRow(
                    title: "Screen & system audio",
                    state: snapshot.screenCapture,
                    statusID: AccessibilityIDs.Settings.permissionScreenCaptureStatus,
                    requestID: AccessibilityIDs.Settings.requestScreenCaptureButton,
                    action: requestScreenCapturePermission
                )
            } footer: {
                Text("System audio capture goes through ScreenCaptureKit, which is gated behind the Screen Recording permission even though we never record video.")
                    .foregroundStyle(Palette.labelSecondary)
                    .font(.footnote)
            }

            Section {
                HStack {
                    Button("Refresh", action: onRefresh)
                        .disabled(permissionsBusy)
                        .accessibilityIdentifier(AccessibilityIDs.Settings.refreshPermissionsButton)
                    Spacer(minLength: 0)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        state: CapturePermissionSnapshot.State,
        statusID: String,
        requestID: String,
        action: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Label(state.label, systemImage: state.systemImage)
                    .foregroundStyle(state == .authorized ? DT.systemGreen : DT.systemOrange)
                    .accessibilityIdentifier(statusID)

                if state != .authorized {
                    Button("Allow", action: action)
                        .disabled(permissionsBusy)
                        .accessibilityIdentifier(requestID)
                }
            }
        }
    }

    private func requestMicrophonePermission() {
        Task { @MainActor in
            permissionsBusy = true
            _ = await CapturePermissionPrimer.shared.requestMicrophoneAccess()
            snapshot = CapturePermissionPrimer.shared.snapshot()
            permissionsBusy = false
        }
    }

    private func requestScreenCapturePermission() {
        permissionsBusy = true
        _ = CapturePermissionPrimer.shared.requestScreenCaptureAccess()
        snapshot = CapturePermissionPrimer.shared.snapshot()
        permissionsBusy = false
    }
}
