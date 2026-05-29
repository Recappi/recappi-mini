import AVFoundation
import SwiftUI

struct MicrophoneInputPicker: View {
    let title: String
    @Binding var selection: String
    var hidesLabel = false
    var accessibilityIdentifier: String

    @State private var options = MicrophoneInputDevice.pickerOptions(selectedID: AppConfig.shared.recordingMicrophoneDeviceID)

    var body: some View {
        Picker(title, selection: normalizedSelectionBinding) {
            ForEach(options) { option in
                Text(option.title)
                    .tag(option.id)
                    .disabled(option.isUnavailable)
            }
        }
        .recappiLabelsHidden(hidesLabel)
        .pickerStyle(.menu)
        .accessibilityIdentifier(accessibilityIdentifier)
        .onAppear(perform: refreshOptions)
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            refreshOptions()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            refreshOptions()
        }
    }

    private var normalizedSelectionBinding: Binding<String> {
        Binding(
            get: {
                selection.trimmingCharacters(in: .whitespacesAndNewlines)
            },
            set: {
                selection = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
    }

    private func refreshOptions() {
        options = MicrophoneInputDevice.pickerOptions(selectedID: selection)
    }
}

private extension View {
    @ViewBuilder
    func recappiLabelsHidden(_ hidden: Bool) -> some View {
        if hidden {
            labelsHidden()
        } else {
            self
        }
    }
}
