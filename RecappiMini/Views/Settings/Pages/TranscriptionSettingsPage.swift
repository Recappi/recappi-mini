import SwiftUI

struct TranscriptionSettingsPage: View {
    @EnvironmentObject private var config: AppConfig
    @ObservedObject private var codexAppServer = CodexAppServerManager.shared

    var body: some View {
        Form {
            SettingsPageHeader(
                title: "Transcription",
                subtitle: "Live captions while recording, and the language used by Apple Speech and the cloud.",
                systemImage: "text.bubble",
                color: .green
            )

            Section {
                Toggle("Show Live Captions while recording", isOn: liveCaptionsDisplayBinding)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.liveCaptionsDisplayToggle)

                Picker("Speech language", selection: languageBinding) {
                    ForEach(SpeechLanguageOption.common) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .accessibilityIdentifier(AccessibilityIDs.Settings.speechLanguagePicker)
            } footer: {
                Text("Live Captions are an optional floating display while recording. Speech language is also used for cloud transcription because Apple Speech cannot reliably auto-detect spoken language.")
                    .foregroundStyle(Palette.labelSecondary)
                    .font(.footnote)
            }

            Section {
                Toggle("Use Codex Realtime", isOn: codexRealtimeBinding)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.experimentalCodexRealtimeToggle)

                Text(codexRealtimeStatusText)
                    .foregroundStyle(Palette.labelSecondary)
                    .font(.footnote)
            } header: {
                Text("Experimental")
            } footer: {
                Text("Starts a local Codex app-server for a future Realtime meeting panel. This is off by default and uses the local Codex login on this Mac.")
                    .foregroundStyle(Palette.labelSecondary)
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { config.cloudLanguage },
            set: { config.cloudLanguage = $0 }
        )
    }

    private var liveCaptionsDisplayBinding: Binding<Bool> {
        Binding(
            get: { config.liveCaptionsDisplayEnabled },
            set: {
                config.liveCaptionsDisplayEnabled = $0
                AppDelegate.shared.applyLiveCaptionDisplayPreference()
            }
        )
    }

    private var codexRealtimeBinding: Binding<Bool> {
        Binding(
            get: { config.experimentalCodexRealtimeEnabled },
            set: {
                config.experimentalCodexRealtimeEnabled = $0
                CodexAppServerManager.shared.syncWithPreference()
            }
        )
    }

    private var codexRealtimeStatusText: String {
        guard config.experimentalCodexRealtimeEnabled else {
            return "Off. Apple Speech remains the default live caption path."
        }

        switch codexAppServer.state {
        case .stopped:
            return "Waiting to start Codex app-server."
        case .starting:
            return "Starting Codex app-server..."
        case .running:
            return "Codex app-server is running for experimental Realtime."
        case .failed(let message):
            return message
        }
    }
}
