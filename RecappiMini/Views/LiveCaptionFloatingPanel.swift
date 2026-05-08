import SwiftUI

enum LiveCaptionPanelMode: String {
    case expanded
    case compact

    var toggleTitle: String {
        switch self {
        case .expanded:
            return "Lyrics"
        case .compact:
            return "Expand"
        }
    }

    var toggleIcon: String {
        switch self {
        case .expanded:
            return "rectangle.compress.vertical"
        case .compact:
            return "rectangle.expand.vertical"
        }
    }

    var defaultWindowSize: NSSize {
        switch self {
        case .expanded:
            return NSSize(width: 542, height: 440)
        case .compact:
            return NSSize(width: 542, height: 92)
        }
    }

    var windowPadding: CGFloat {
        switch self {
        case .expanded:
            return 10
        case .compact:
            return 8
        }
    }
}

struct LiveCaptionFloatingPanel: View {
    @ObservedObject var recorder: AudioRecorder
    @EnvironmentObject private var config: AppConfig
    let mode: LiveCaptionPanelMode
    let onToggleMode: () -> Void
    let onClose: () -> Void

    var body: some View {
        Group {
            switch mode {
            case .expanded:
                expandedBody
            case .compact:
                compactBody
            }
        }
        .background(panelBackground(cornerRadius: mode == .expanded ? 16 : 14))
        .overlay(
            RoundedRectangle(cornerRadius: mode == .expanded ? 16 : 14, style: .continuous)
                .stroke(Palette.borderSubtle, lineWidth: 0.6)
        )
        .shadow(color: Palette.shadowPanel.opacity(0.42), radius: 5, x: 0, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingPanel)
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            liveCaptionWorkspace
        }
        .padding(12)
        .frame(width: 500, alignment: .topLeading)
    }

    private var compactBody: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(DT.systemRed)
                    .frame(width: 6, height: 6)
                    .modifier(PulsingModifier())
                Text(timeText(recorder.elapsedSeconds))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.dtLabelSecondary)
            }
            .frame(width: 52, alignment: .leading)

            Text(compactCaptionLine)
                .font(.system(size: 15, weight: recorder.liveCaptionText == nil ? .medium : .semibold))
                .foregroundStyle(recorder.liveCaptionText == nil ? Color.dtLabelSecondary : Color.dtLabel)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(compactCaptionLine))
                .accessibilityValue(Text(compactCaptionLine))
                .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaption)

            captionControlButtons
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 514, alignment: .leading)
    }

    private func panelBackground(cornerRadius: CGFloat) -> some View {
        // `.regularMaterial` already adapts to the system appearance; the
        // `Palette.surfaceLiveCaption` overlay provides the slightly tinted
        // surface that gives the captions panel its lifted look in both
        // light and dark themes.
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                Palette.surfaceLiveCaption
                    .opacity(0.88)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
    }

    private var captionControlButtons: some View {
        HStack(spacing: 5) {
            Button(action: onToggleMode) {
                Image(systemName: mode.toggleIcon)
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(PanelIconButtonStyle(size: 22))
            .help(mode.toggleTitle)
            .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingPanelModeButton)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(PanelIconButtonStyle(size: 22))
            .help("Hide live captions for this meeting")
            .accessibilityLabel("Hide live captions")
            .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionCloseButton)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            liveBadge

            VStack(alignment: .leading, spacing: 3) {
                Text("Current meeting")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)
                Text(sourceLine)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Text(timeText(recorder.elapsedSeconds))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.dtLabelSecondary)

            captionControlButtons
        }
    }

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(DT.systemRed)
                .frame(width: 6, height: 6)
            Text("Live")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.dtLabel)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(DT.systemRed.opacity(0.16))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(DT.systemRed.opacity(0.28), lineWidth: 0.6)
        )
    }

    private var liveCaptionWorkspace: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Live captions", systemImage: "captions.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    liveCaptionLanguageMenu
                    systemAudioChip
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            LiveCaptionTextViewport(
                text: captionLine,
                isPlaceholder: recorder.liveCaptionText == nil
            )
            .foregroundStyle(recorder.liveCaptionText == nil ? Color.dtLabelSecondary : Color.dtLabel)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.controlFillHover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Palette.borderHairline, lineWidth: 0.6)
        )
        .frame(height: 318, alignment: .topLeading)
    }

    private var liveCaptionLanguageMenu: some View {
        Menu {
            ForEach(SpeechLanguageOption.common) { option in
                Button {
                    recorder.setSpeechLanguage(option.id)
                } label: {
                    if option.id == config.selectedSpeechLanguage.id {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(config.selectedSpeechLanguage.shortTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.dtLabelTertiary)
            }
            .foregroundStyle(Color.dtLabel)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Palette.controlFillHover)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Live caption language")
        .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingLanguageMenu)
    }

    private var systemAudioChip: some View {
        Text("System audio")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DT.waveformLit)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(DT.waveformLit.opacity(0.12))
            )
    }

    private var captionLine: String {
        if let text = recorder.liveCaptionText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        if let message = recorder.liveCaptionMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        return "Listening for meeting audio…"
    }

    private var compactCaptionLine: String {
        let lines = captionLine
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.last ?? captionLine
    }

    private var sourceLine: String {
        recorder.recordingAppName ?? recorder.selectedApp?.name ?? "All system audio"
    }

    private func timeText(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

private struct LiveCaptionTextViewport: View {
    let text: String
    let isPlaceholder: Bool

    private let bottomAnchorID = "recappi-live-caption-bottom"
    private let expandedTextWidth: CGFloat = 472

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(.system(size: 15, weight: .medium))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: expandedTextWidth, alignment: .topLeading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(text))
                        .accessibilityValue(Text(text))
                        .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaption)

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .frame(width: expandedTextWidth, alignment: .topLeading)
            }
            .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionViewport)
            .contentShape(Rectangle())
            .scrollIndicators(.visible)
            .frame(width: expandedTextWidth, alignment: .topLeading)
            .frame(height: 246, alignment: .topLeading)
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: text) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }
}
