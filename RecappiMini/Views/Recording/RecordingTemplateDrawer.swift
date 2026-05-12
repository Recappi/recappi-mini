import SwiftUI

struct RecordingTemplateDrawer: View {
    @ObservedObject private var config = AppConfig.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .overlay(Palette.borderHairline.opacity(0.3))
            configRow
            promptEditor
        }
        .padding(.top, 6)
        .padding(.horizontal, 2)
        .transition(.opacity)
        .accessibilityIdentifier(AccessibilityIDs.Panel.templateDrawer)
    }

    private var scene: RecordingSceneTemplate {
        RecordingSceneTemplate.option(for: config.recordingSceneTemplate)
    }

    private var configRow: some View {
        HStack(spacing: 7) {
            sceneMenu

            Button {
                config.recordingIncludeMicrophoneAudio.toggle()
            } label: {
                Image(systemName: config.recordingIncludeMicrophoneAudio ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(RecordingTemplateIconToggleStyle(isSelected: config.recordingIncludeMicrophoneAudio))
            .help(config.recordingIncludeMicrophoneAudio ? "Microphone included" : "Microphone muted")

            promptDisclosureButton
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var sceneMenu: some View {
        Menu {
            ForEach(RecordingSceneTemplate.allCases) { option in
                Button {
                    config.recordingSceneTemplate = option.rawValue
                } label: {
                    Label(option.title, systemImage: option == scene ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text("Scene")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.labelTertiary)
                Text(scene.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Palette.labelPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Palette.labelTertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .fill(Palette.surfaceCardSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .stroke(Palette.borderHairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Choose recording scene")
        .fixedSize(horizontal: true, vertical: false)
    }

    private var promptDisclosureButton: some View {
        Button {
            config.recordingTemplatePromptExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: config.recordingTemplatePromptExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Palette.labelTertiary)
                Text("Prompt")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.labelPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
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
        .help("Used for cloud transcription and summary. Live captions do not use this prompt.")
        .accessibilityIdentifier(AccessibilityIDs.Panel.promptDisclosureButton)
    }

    @ViewBuilder
    private var promptEditor: some View {
        if config.recordingTemplatePromptExpanded {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $config.recordingExtraPrompt)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.labelPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(6)

                if config.recordingExtraPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Add names, terms, or goals to improve summary")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.labelTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 11)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 52, maxHeight: 70)
            .background(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .fill(Palette.surfaceCardSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .stroke(Palette.borderHairline, lineWidth: 0.5)
            )
            .accessibilityIdentifier(AccessibilityIDs.Panel.promptField)
            .transition(.opacity)
        }
    }
}

private struct RecordingTemplateIconToggleStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Palette.labelPrimary : Palette.labelTertiary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .fill(chipFill(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .stroke(isSelected ? Palette.borderSubtle : Palette.borderHairline, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: DT.R.control, style: .continuous))
            .animation(DT.motionAware(DT.ease(0.12)), value: configuration.isPressed)
            .animation(DT.motionAware(DT.ease(0.15)), value: isSelected)
    }

    private func chipFill(isPressed: Bool) -> Color {
        if isPressed { return Palette.controlFillPress }
        if isSelected { return Palette.controlFillHover }
        return Palette.surfaceCardSubtle
    }
}
