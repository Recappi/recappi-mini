import AppKit
import SwiftUI

struct RecordingOptionsButton: View {
    let isDisabled: Bool

    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var config = AppConfig.shared
    @State private var isShowingOptions = false
    @State private var isPromptExpanded = false
    @State private var promptEditorMeasuredHeight: CGFloat = 44

    private var scene: RecordingSceneTemplate {
        RecordingSceneTemplate.option(for: config.recordingSceneTemplate)
    }

    var body: some View {
        Button {
            // Force Recording panel + app to take focus so the popover renders
            // controls in their active appearance instead of inactive (dim) state.
            // FloatingPanel uses `becomesKeyOnlyIfNeeded = true` to avoid stealing
            // focus on normal interaction, so we explicitly request key state
            // only when the user is opening the configuration popover.
            if !isShowingOptions {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.keyWindow
                    ?? NSApp.windows.first(where: { $0 is FloatingPanel && $0.isVisible }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
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
        .recappiTooltip("Configure recording options")
        .popover(isPresented: $isShowingOptions, arrowEdge: .top) {
            optionsPopover
        }
        .accessibilityIdentifier(AccessibilityIDs.Panel.recordingOptionsButton)
    }

    private var optionsPopover: some View {
        VStack(alignment: .leading, spacing: 22) {
            optionsSection("Audio capture") {
                optionsPickerRow("Language") {
                    Picker("Language", selection: speechLanguageBinding) {
                        ForEach(SpeechLanguageOption.common) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier(AccessibilityIDs.Panel.sharedLanguageButton)
                }

                optionsPickerRow("Microphone") {
                    MicrophoneInputPicker(
                        title: "Microphone",
                        selection: microphoneDeviceBinding,
                        hidesLabel: true,
                        accessibilityIdentifier: AccessibilityIDs.Panel.microphoneInputPicker
                    )
                    .controlSize(.small)
                }

                optionsToggleRow(
                    "Include microphone",
                    subtitle: "Mix your microphone into the recording",
                    isOn: $config.recordingIncludeMicrophoneAudio,
                    accessibilityID: AccessibilityIDs.Panel.microphoneIncludeButton
                )
            }

            optionsSection("Live captions") {
                optionsToggleRow(
                    "Enable",
                    subtitle: "Show a floating caption strip while recording",
                    isOn: liveCaptionDisplayBinding,
                    accessibilityID: AccessibilityIDs.Panel.liveCaptionDisplayToggle
                )

                optionsPickerRow("Translate") {
                    Picker("Translate", selection: translateModeBinding) {
                        Text("Off").tag("")
                        Divider()
                        ForEach(LiveCaptionTranslationTargetLanguageOption.common) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(!canConfigureTranslation)
                    .accessibilityIdentifier(AccessibilityIDs.Panel.liveCaptionTranslateToggle)
                }

            }

            optionsSection("Cloud transcription") {
                optionsPickerRow("Scene") {
                    Picker("Scene", selection: $config.recordingSceneTemplate) {
                        ForEach(RecordingSceneTemplate.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier(AccessibilityIDs.Panel.summaryScenePicker)
                }

                optionsToggleRow(
                    "Auto-process after upload",
                    subtitle: "Start transcript and summary as soon as upload finishes",
                    isOn: $config.recordingAutoTranscribeAfterUpload,
                    accessibilityID: AccessibilityIDs.Panel.autoTranscribeToggle
                )

                promptDisclosure
            }

            Divider()
                .overlay(Palette.borderSubtle)

            Button {
                isShowingOptions = false
                AppDelegate.shared.prepareForSettingsScenePresentation()
                openSettings()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 16)
                    Text("Open Settings…")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.labelTertiary)
                }
                .foregroundStyle(Palette.labelSecondary)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .recappiTooltip("Open Recappi Mini Settings")
            .accessibilityIdentifier(AccessibilityIDs.Panel.recordingOptionsSettingsButton)
        }
        .padding(18)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Palette.borderSubtle, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIDs.Panel.recordingOptionsPopover)
        .onAppear {
            if !config.recordingExtraPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isPromptExpanded = true
            }
        }
    }

    private func optionsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(DT.statusReady)
                .tracking(0.8)
            VStack(alignment: .leading, spacing: 10, content: content)
        }
    }

    private func optionsPickerRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.labelPrimary)
            Spacer(minLength: 12)
            control()
                .controlSize(.small)
        }
        .frame(minHeight: 26)
    }

    private func optionsToggleRow(
        _ title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        accessibilityID: String
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.labelPrimary)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.labelTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                switchGlyph(isOn: isOn.wrappedValue)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityIdentifier(accessibilityID)
    }

    private func switchGlyph(isOn: Bool) -> some View {
        Capsule(style: .continuous)
            .fill(isOn ? DT.recordingLiveBlue : Palette.surfaceChip)
            .frame(width: 34, height: 20)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                    .padding(2)
            }
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Palette.borderHairline, lineWidth: 0.5)
            )
            .animation(DT.motionAware(DT.ease(0.14)), value: isOn)
    }

    @ViewBuilder
    private var promptDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(DT.motionAware(DT.ease(0.16))) {
                    isPromptExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isPromptExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("Add prompt context")
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DT.recordingLiveBlue)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityIDs.Panel.promptDisclosureButton)

            if isPromptExpanded {
                AlignedPromptTextView(
                    text: $config.recordingExtraPrompt,
                    measuredHeight: $promptEditorMeasuredHeight,
                    placeholder: "Names, terms, goals…",
                    fontSize: 11,
                    textInset: NSSize(width: 8, height: 8),
                    accessibilityIdentifier: AccessibilityIDs.Panel.promptField,
                    isEditable: true
                )
                .frame(minHeight: 46, maxHeight: max(46, promptEditorMeasuredHeight))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.surfaceChip.opacity(0.65))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.borderSubtle, lineWidth: 0.5)
                )
                .animation(DT.motionAware(DT.ease(0.15)), value: promptEditorMeasuredHeight)
            }
        }
    }

    private var canConfigureTranslation: Bool {
        config.liveCaptionsDisplayEnabled
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

    private var microphoneDeviceBinding: Binding<String> {
        Binding(
            get: { config.recordingMicrophoneDeviceID },
            set: { config.recordingMicrophoneDeviceID = $0 }
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
                        config.liveCaptionsBilingualEnabled = true
                    }
                }
            }
        )
    }
}
