import SwiftUI

struct TranscriptionSettingsPage: View {
    @EnvironmentObject private var config: AppConfig

    var body: some View {
        Form {
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
                Text("Live Captions are an optional floating display while recording. Speech language is used for cloud transcription and backend Realtime captions.")
                    .foregroundStyle(Palette.labelSecondary)
                    .font(.footnote)
            }

            Section {
                Toggle("Bilingual captions (original + translation)", isOn: bilingualBinding)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.liveCaptionsBilingualToggle)

                Picker("Translation target language", selection: bilingualTargetLanguageBinding) {
                    ForEach(LiveCaptionTranslationTargetLanguageOption.common) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .disabled(!config.liveCaptionsBilingualEnabled)
                .accessibilityIdentifier(AccessibilityIDs.Settings.liveCaptionsBilingualTargetLanguagePicker)
            } footer: {
                Text("When enabled, the live caption panel renders both the original transcript and a translation in the target language through backend Realtime.")
                    .foregroundStyle(Palette.labelSecondary)
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
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

    private var bilingualBinding: Binding<Bool> {
        Binding(
            get: { config.liveCaptionsBilingualEnabled },
            set: { config.liveCaptionsBilingualEnabled = $0 }
        )
    }

    private var bilingualTargetLanguageBinding: Binding<String> {
        Binding(
            get: { config.liveCaptionsTranslationTargetLanguage },
            set: { config.liveCaptionsTranslationTargetLanguage = $0 }
        )
    }
}
