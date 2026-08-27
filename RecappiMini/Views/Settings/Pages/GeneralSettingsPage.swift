import AppKit
import SwiftUI

private struct RecordingDurationOption: Identifiable, Hashable {
    let minutes: Int
    let title: String

    var id: Int { minutes }
}

private let longRecordingReminderOptions: [RecordingDurationOption] = [
    .init(minutes: 0, title: "Never"),
    .init(minutes: 30, title: "30 min"),
    .init(minutes: 45, title: "45 min"),
    .init(minutes: 60, title: "1 hr"),
    .init(minutes: 120, title: "2 hr"),
]

private let maxRecordingDurationOptions: [RecordingDurationOption] = [
    .init(minutes: 0, title: "No limit"),
    .init(minutes: 120, title: "2 hr"),
    .init(minutes: 240, title: "4 hr"),
    .init(minutes: 360, title: "6 hr"),
    .init(minutes: 480, title: "8 hr"),
]

struct GeneralSettingsPage: View {
    @EnvironmentObject private var config: AppConfig

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: themeBinding) {
                    ForEach(AppTheme.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(AccessibilityIDs.Settings.themePicker)
            } footer: {
                Text("Choose Light, Dark, or follow your macOS appearance.")
                    .foregroundStyle(Palette.labelSecondary)
                    .font(.footnote)
            }

            Section {
                MicrophoneInputPicker(
                    title: "Microphone input",
                    selection: microphoneDeviceBinding,
                    accessibilityIdentifier: AccessibilityIDs.Settings.microphoneInputPicker
                )
            } footer: {
                Text("Used when Include microphone is on. If the selected microphone is unavailable, Recappi falls back to the macOS default input.")
                    .foregroundStyle(Palette.labelSecondary)
                    .font(.footnote)
            }

            Section {
                Toggle("Suggest recording when app audio starts", isOn: autoPromptBinding)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.autoPromptToggle)
            } footer: {
                Text("When a meeting app or browser meeting tab starts playing audio, Recappi Mini opens the panel and explains which app looks ready to record.")
                    .foregroundStyle(Palette.labelSecondary)
                    .font(.footnote)
            }

            Section {
                Picker("Hidden recording reminder", selection: longReminderBinding) {
                    ForEach(longRecordingReminderOptions) { option in
                        Text(option.title).tag(option.minutes)
                    }
                }
                .accessibilityIdentifier(AccessibilityIDs.Settings.longRecordingReminderPicker)

                Toggle("Suggest stop when audio goes quiet", isOn: suspectedForgottenStopBinding)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.suspectedForgottenStopToggle)

                Picker("Recording limit", selection: maxDurationBinding) {
                    ForEach(maxRecordingDurationOptions) { option in
                        Text(option.title).tag(option.minutes)
                    }
                }
                .accessibilityIdentifier(AccessibilityIDs.Settings.maxRecordingDurationPicker)
            } footer: {
                Text("Recappi keeps saving the recording; these prompts only bring you back when a background capture looks forgotten.")
                    .foregroundStyle(Palette.labelSecondary)
                    .font(.footnote)
            }

            Section {
                LabeledContent("Recordings folder") {
                    Button("Show in Finder", action: openRecordingsFolder)
                }
            } footer: {
                Text("Recordings are saved in ~/Documents/Recappi Mini.")
                    .foregroundStyle(Palette.labelSecondary)
                    .font(.footnote)
            }

            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restart onboarding")
                            .font(.body)
                            .foregroundStyle(Palette.labelPrimary)
                        Text("Replays the welcome screen, permission walkthrough, and sign-in step.")
                            .font(.footnote)
                            .foregroundStyle(Palette.labelSecondary)
                    }
                    Spacer(minLength: 12)
                    Button("Restart", action: restartOnboarding)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
    }

    private var autoPromptBinding: Binding<Bool> {
        Binding(
            get: { config.autoPromptForActiveAudioApps },
            set: { config.autoPromptForActiveAudioApps = $0 }
        )
    }

    private var longReminderBinding: Binding<Int> {
        Binding(
            get: { config.recordingLongReminderMinutes },
            set: { config.recordingLongReminderMinutes = $0 }
        )
    }

    private var suspectedForgottenStopBinding: Binding<Bool> {
        Binding(
            get: { config.recordingSuspectedForgottenStopEnabled },
            set: { config.recordingSuspectedForgottenStopEnabled = $0 }
        )
    }

    private var maxDurationBinding: Binding<Int> {
        Binding(
            get: { config.recordingMaxDurationMinutes },
            set: { config.recordingMaxDurationMinutes = $0 }
        )
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: { config.theme },
            set: { config.theme = $0 }
        )
    }

    private var microphoneDeviceBinding: Binding<String> {
        Binding(
            get: { config.recordingMicrophoneDeviceID },
            set: { config.recordingMicrophoneDeviceID = $0 }
        )
    }

    private func openRecordingsFolder() {
        NSWorkspace.shared.open(RecordingStore.baseDirectory)
    }

    private func restartOnboarding() {
        OnboardingState.didComplete = false
        OnboardingState.lastStep = .welcome
        AppDelegate.shared.showOnboardingWindow()
    }
}
