import SwiftUI

struct RecordingTemplateDrawer: View {
    let onHide: () -> Void

    @ObservedObject private var config = AppConfig.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            configRow
            promptEditor
        }
        .padding(.top, 5)
        .transition(.opacity)
    }

    private var scene: RecordingSceneTemplate {
        RecordingSceneTemplate.option(for: config.recordingSceneTemplate)
    }

    private var configRow: some View {
        HStack(spacing: 6) {
            Button(action: onHide) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.labelTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide panel")
            .accessibilityLabel("Hide panel")
            .accessibilityIdentifier(AccessibilityIDs.Panel.closeButton)

            sceneMenu
                .frame(maxWidth: .infinity)

            promptDisclosureButton
                .frame(maxWidth: .infinity)
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
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Palette.labelTertiary)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
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
        .help("Choose recording scene")
    }

    private var promptDisclosureButton: some View {
        Button {
            config.recordingTemplatePromptExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: config.recordingTemplatePromptExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Palette.labelTertiary)
                Text("Prompt")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.labelPrimary)
                    .lineLimit(1)
                Text("transcription")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(Palette.labelTertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
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
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
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
