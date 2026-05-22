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

            Section {
                Toggle("Use backend Realtime captions", isOn: backendRealtimeBinding)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.backendRealtimeLiveCaptionsToggle)
            } footer: {
                Text("Experimental. When enabled, Recappi streams live caption audio through the authenticated backend Realtime WebSocket instead of Apple Speech.")
                    .foregroundStyle(Palette.labelSecondary)
                    .font(.footnote)
            }

            Section {
                Toggle("Bilingual captions (original + translation)", isOn: bilingualBinding)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.liveCaptionsBilingualToggle)
                    .disabled(!config.backendRealtimeLiveCaptionsEnabled)

                Picker("Translation target language", selection: bilingualTargetLanguageBinding) {
                    ForEach(LiveCaptionTranslationTargetLanguageOption.common) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .disabled(!config.backendRealtimeLiveCaptionsEnabled || !config.liveCaptionsBilingualEnabled)
                .accessibilityIdentifier(AccessibilityIDs.Settings.liveCaptionsBilingualTargetLanguagePicker)
            } footer: {
                Text("When enabled, the live caption panel renders both the original transcript and a translation in the target language. Requires backend Realtime captions and uses OpenAI's translation Realtime endpoint.")
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

    private var backendRealtimeBinding: Binding<Bool> {
        Binding(
            get: { config.backendRealtimeLiveCaptionsEnabled },
            set: { config.backendRealtimeLiveCaptionsEnabled = $0 }
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
