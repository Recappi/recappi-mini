import AppKit
import SwiftUI

struct RecordingOptionsButton: View {
    let isDisabled: Bool

    @ObservedObject private var config = AppConfig.shared
    @State private var isShowingOptions = false
    @State private var promptEditorMeasuredHeight: CGFloat = 44

    private var scene: RecordingSceneTemplate {
        RecordingSceneTemplate.option(for: config.recordingSceneTemplate)
    }

    var body: some View {
        Button {
            isShowingOptions.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.labelTertiary)
                Text("Options")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.labelPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Palette.labelTertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .fill(DT.recordingChip.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .stroke(Palette.borderHairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.72 : 1)
        .help("Configure recording options")
        .popover(isPresented: $isShowingOptions, arrowEdge: .top) {
            optionsPopover
        }
        .accessibilityIdentifier(AccessibilityIDs.Panel.recordingOptionsButton)
    }

    private var optionsPopover: some View {
        Form {
            Section {
                Picker("Language", selection: speechLanguageBinding) {
                    ForEach(SpeechLanguageOption.common) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .accessibilityIdentifier(AccessibilityIDs.Panel.sharedLanguageButton)

                Toggle("Include microphone", isOn: $config.recordingIncludeMicrophoneAudio)
                    .accessibilityIdentifier(AccessibilityIDs.Panel.microphoneIncludeButton)
            }

            Section("Live captions") {
                Toggle("Enable", isOn: liveCaptionDisplayBinding)
                    .accessibilityIdentifier(AccessibilityIDs.Panel.liveCaptionDisplayToggle)

                Picker("Translate", selection: translateModeBinding) {
                    Text("Off").tag("")
                    Divider()
                    ForEach(LiveCaptionTranslationTargetLanguageOption.common) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .disabled(!canConfigureTranslation)
                .accessibilityIdentifier(AccessibilityIDs.Panel.liveCaptionTranslateToggle)

                if !config.backendRealtimeLiveCaptionsEnabled {
                    Text("Translation requires backend Realtime captions in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Cloud transcription") {
                Picker("Scene", selection: $config.recordingSceneTemplate) {
                    ForEach(RecordingSceneTemplate.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .accessibilityIdentifier(AccessibilityIDs.Panel.summaryScenePicker)

                Toggle("Run after upload", isOn: $config.recordingAutoTranscribeAfterUpload)
                    .accessibilityIdentifier(AccessibilityIDs.Panel.autoTranscribeToggle)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    AlignedPromptTextView(
                        text: $config.recordingExtraPrompt,
                        measuredHeight: $promptEditorMeasuredHeight,
                        placeholder: "Add context: names, terms, goals…",
                        fontSize: 11,
                        textInset: NSSize(width: 7, height: 7),
                        accessibilityIdentifier: AccessibilityIDs.Panel.promptField,
                        isEditable: true
                    )
                    .frame(minHeight: 44, maxHeight: max(44, promptEditorMeasuredHeight))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.gray.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.gray.opacity(0.25), lineWidth: 0.5)
                    )
                    .animation(DT.motionAware(DT.ease(0.15)), value: promptEditorMeasuredHeight)
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 360)
        .frame(minHeight: 320, idealHeight: 400, maxHeight: 500)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier(AccessibilityIDs.Panel.recordingOptionsPopover)
    }

    private var canConfigureTranslation: Bool {
        config.liveCaptionsDisplayEnabled && config.backendRealtimeLiveCaptionsEnabled
    }

    private var liveCaptionDisplayBinding: Binding<Bool> {
        Binding(
            get: { config.liveCaptionsDisplayEnabled },
            set: {
                config.liveCaptionsDisplayEnabled = $0
                AppDelegate.shared.applyLiveCaptionDisplayPreference()
            }
        )
    }

    private var speechLanguageBinding: Binding<String> {
        Binding(
            get: { SpeechLanguageOption.option(for: config.cloudLanguage).id },
            set: { config.cloudLanguage = SpeechLanguageOption.option(for: $0).id }
        )
    }

    /// Combined "Off + target lang" picker binding.
    /// Empty string represents "Off" (translation disabled).
    /// Non-empty string represents a target language id with translation enabled.
    private var translateModeBinding: Binding<String> {
        Binding(
            get: {
                guard config.liveCaptionsBilingualEnabled else { return "" }
                return LiveCaptionTranslationTargetLanguageOption.normalizedCode(
                    config.liveCaptionsTranslationTargetLanguage
                )
            },
            set: { newValue in
                withAnimation(DT.motionAware(DT.ease(0.15))) {
                    if newValue.isEmpty {
                        config.liveCaptionsBilingualEnabled = false
                    } else {
                        config.liveCaptionsTranslationTargetLanguage =
                            LiveCaptionTranslationTargetLanguageOption.normalizedCode(newValue)
                        config.liveCaptionsBilingualEnabled = config.backendRealtimeLiveCaptionsEnabled
                    }
                }
            }
        )
    }
}
