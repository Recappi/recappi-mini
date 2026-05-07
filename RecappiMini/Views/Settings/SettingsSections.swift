import SwiftUI

struct SettingsAccountSection<StatusStrip: View, IdentityRow: View, SignedOutRow: View, BillingUsage: View>: View {
    let currentSession: UserSession?
    @Binding var cloudEnabled: Bool
    let isOpenCloudDisabled: Bool
    let onOpenCloud: () -> Void
    @ViewBuilder let statusStrip: () -> StatusStrip
    @ViewBuilder let identityRow: (UserSession) -> IdentityRow
    @ViewBuilder let signedOutRow: () -> SignedOutRow
    @ViewBuilder let billingUsage: () -> BillingUsage

    var body: some View {
        Section {
            statusStrip()

            if let currentSession {
                identityRow(currentSession)
            } else {
                signedOutRow()
            }

            Toggle("Cloud transcription", isOn: $cloudEnabled)
                .accessibilityIdentifier(AccessibilityIDs.Settings.cloudToggle)

            billingUsage()

            HStack {
                Button("Open Recappi Cloud", action: onOpenCloud)
                    .disabled(isOpenCloudDisabled)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.openCloudButton)
                Spacer(minLength: 0)
            }
        } header: {
            Text("Account")
        }
    }
}

struct SettingsPermissionsSection<MicrophoneRow: View, ScreenCaptureRow: View>: View {
    let permissionsBusy: Bool
    let onRefresh: () -> Void
    @ViewBuilder let microphoneRow: () -> MicrophoneRow
    @ViewBuilder let screenCaptureRow: () -> ScreenCaptureRow

    var body: some View {
        Section {
            microphoneRow()
            screenCaptureRow()

            HStack {
                Button("Refresh", action: onRefresh)
                    .disabled(permissionsBusy)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.refreshPermissionsButton)
                Spacer(minLength: 0)
            }
        } header: {
            Text("Permissions")
        }
    }
}

struct SettingsAppearanceSection: View {
    @Binding var theme: AppTheme

    var body: some View {
        Section {
            Picker("Theme", selection: $theme) {
                ForEach(AppTheme.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(AccessibilityIDs.Settings.themePicker)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Choose Light, Dark, or follow your macOS appearance.")
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
        }
    }
}

struct SettingsRecordingAssistSection: View {
    @Binding var autoPrompt: Bool

    var body: some View {
        Section {
            Toggle("Suggest recording when app audio starts", isOn: $autoPrompt)
                .accessibilityIdentifier(AccessibilityIDs.Settings.autoPromptToggle)
        } header: {
            Text("Recording Assist")
        } footer: {
            Text("When a meeting app or browser meeting tab starts playing audio, Recappi Mini opens the panel and explains which app looks ready to record.")
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
        }
    }
}

struct SettingsTranscriptionSection: View {
    @Binding var liveCaptionsDisplay: Bool
    @Binding var language: String

    var body: some View {
        Section {
            Toggle("Show Live Captions while recording", isOn: $liveCaptionsDisplay)
                .accessibilityIdentifier(AccessibilityIDs.Settings.liveCaptionsDisplayToggle)

            Picker("Speech language", selection: $language) {
                ForEach(SpeechLanguageOption.common) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .accessibilityIdentifier(AccessibilityIDs.Settings.speechLanguagePicker)
        } header: {
            Text("Transcription")
        } footer: {
            Text("Live Captions are an optional floating display while recording. Speech language is also used for cloud transcription because Apple Speech cannot reliably auto-detect spoken language.")
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
        }
    }
}

struct SettingsStorageSection: View {
    let onOpenRecordingsFolder: () -> Void

    var body: some View {
        Section {
            LabeledContent("Recordings folder") {
                Button("Show in Finder", action: onOpenRecordingsFolder)
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Recordings are saved in ~/Documents/Recappi Mini.")
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
        }
    }
}

struct SettingsUpdatesSection: View {
    @ObservedObject var appUpdater: AppUpdater
    let appVersionText: String
    let lastUpdateCheckText: String

    var body: some View {
        Section {
            LabeledContent("Current version") {
                Text(appVersionText)
                    .foregroundStyle(Color.dtLabelSecondary)
            }

            LabeledContent("Last checked") {
                Text(lastUpdateCheckText)
                    .foregroundStyle(Color.dtLabelSecondary)
            }

            Toggle(
                "Automatically check for updates",
                isOn: Binding(
                    get: { appUpdater.automaticallyChecksForUpdates },
                    set: { appUpdater.setAutomaticallyChecksForUpdates($0) }
                )
            )

            Toggle(
                "Automatically download updates",
                isOn: Binding(
                    get: { appUpdater.automaticallyDownloadsUpdates },
                    set: { appUpdater.setAutomaticallyDownloadsUpdates($0) }
                )
            )
            .disabled(!appUpdater.automaticallyChecksForUpdates)

            HStack {
                Button("Check for Updates…") {
                    appUpdater.checkForUpdates()
                }
                .disabled(!appUpdater.canCheckForUpdates)
                Spacer(minLength: 0)
            }
        } header: {
            Text("Updates")
        }
    }
}

struct SettingsSupportSection: View {
    let onRestartOnboarding: () -> Void
    let onShowAbout: () -> Void

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restart onboarding")
                        .font(.body)
                    Text("Replays the welcome screen, permission walkthrough, and sign-in step.")
                        .font(.footnote)
                        .foregroundStyle(Color.dtLabelSecondary)
                }
                Spacer(minLength: 12)
                Button("Restart", action: onRestartOnboarding)
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("About Recappi Mini")
                        .font(.body)
                    Text("Shows version, build, and application identity.")
                        .font(.footnote)
                        .foregroundStyle(Color.dtLabelSecondary)
                }
                Spacer(minLength: 12)
                Button("About", action: onShowAbout)
            }
        } header: {
            Text("Help")
        }
    }
}
