import AppKit
import SwiftUI

struct RecordingTemplateDrawer: View {
    let onHide: () -> Void

    @ObservedObject private var config = AppConfig.shared
    @State private var promptEditorMeasuredHeight: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: config.recordingTemplatePromptExpanded ? 10 : 0) {
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
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PanelIconButtonStyle(size: 28))
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
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                config.recordingTemplatePromptExpanded.toggle()
            }
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
        let isExpanded = config.recordingTemplatePromptExpanded

        AlignedPromptTextView(
            text: $config.recordingExtraPrompt,
            measuredHeight: $promptEditorMeasuredHeight,
            placeholder: "Add names, terms, or goals to improve summary",
            fontSize: 11,
            textInset: NSSize(width: 6, height: 6),
            accessibilityIdentifier: AccessibilityIDs.Panel.promptField,
            isEditable: isExpanded
        )
        .frame(height: isExpanded ? max(28, promptEditorMeasuredHeight) : 0)
        .opacity(isExpanded ? 1 : 0)
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                .fill(Palette.surfaceCardSubtle)
                .opacity(isExpanded ? 1 : 0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                .stroke(Palette.borderHairline, lineWidth: 0.5)
                .opacity(isExpanded ? 1 : 0)
        )
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
    }
}
