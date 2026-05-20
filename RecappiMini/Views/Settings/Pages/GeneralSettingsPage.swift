import AppKit
import SwiftUI

struct GeneralSettingsPage: View {
    @EnvironmentObject private var config: AppConfig

    var body: some View {
        Form {
            SettingsPageHeader(
                title: "General",
                subtitle: "App-wide preferences — appearance, recording suggestions, where files live.",
                systemImage: "gear",
                color: .gray
            )

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
                Toggle("Suggest recording when app audio starts", isOn: autoPromptBinding)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.autoPromptToggle)
            } footer: {
                Text("When a meeting app or browser meeting tab starts playing audio, Recappi Mini opens the panel and explains which app looks ready to record.")
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
                LabeledContent("Diagnostics logs") {
                    HStack(spacing: 8) {
                        Button("Open Logs Folder", action: openLogsFolder)
                            .accessibilityIdentifier(AccessibilityIDs.Settings.openLogsFolderButton)
                        Button("Copy Path", action: copyLogsPath)
                            .accessibilityIdentifier(AccessibilityIDs.Settings.copyLogsPathButton)
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Path")
                        .foregroundStyle(Palette.labelPrimary)
                    Spacer(minLength: 12)
                    Text(DiagnosticsLog.logsDirectoryURL.path)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Palette.labelSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(DiagnosticsLog.logsDirectoryURL.path)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("When reporting an issue, send diagnostics.log plus any diagnostics.*.log files from this folder.")
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
        .scrollContentBackground(.hidden)
    }

    private var autoPromptBinding: Binding<Bool> {
        Binding(
            get: { config.autoPromptForActiveAudioApps },
            set: { config.autoPromptForActiveAudioApps = $0 }
        )
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: { config.theme },
            set: { config.theme = $0 }
        )
    }

    private func openRecordingsFolder() {
        NSWorkspace.shared.open(RecordingStore.baseDirectory)
    }

    private func openLogsFolder() {
        DiagnosticsLog.event("diagnostics", "open_logs_folder source=settings")
        NSWorkspace.shared.open(DiagnosticsLog.logsDirectoryURL)
    }

    private func copyLogsPath() {
        DiagnosticsLog.event("diagnostics", "copy_logs_path source=settings")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DiagnosticsLog.logsDirectoryURL.path, forType: .string)
    }

    private func restartOnboarding() {
        OnboardingState.didComplete = false
        OnboardingState.lastStep = .welcome
        AppDelegate.shared.showOnboardingWindow()
    }
}
