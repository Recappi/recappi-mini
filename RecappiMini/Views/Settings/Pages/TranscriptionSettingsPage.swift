import SwiftUI

struct TranscriptionSettingsPage: View {
    @EnvironmentObject private var config: AppConfig

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
}
