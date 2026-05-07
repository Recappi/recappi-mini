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
            return NSSize(width: 486, height: 460)
        case .compact:
            return NSSize(width: 688, height: 92)
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
        .background(panelBackground(cornerRadius: mode == .expanded ? 22 : 18))
        .overlay(
            RoundedRectangle(cornerRadius: mode == .expanded ? 22 : 18, style: .continuous)
                .stroke(Color.white.opacity(0.13), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(0.24), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingPanel)
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            liveCaptionWorkspace
        }
        .padding(16)
        .frame(width: 438, alignment: .topLeading)
    }

    private var compactBody: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(DT.systemRed)
                    .frame(width: 7, height: 7)
                    .modifier(PulsingModifier())
                Text(timeText(recorder.elapsedSeconds))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.dtLabelSecondary)
            }
            .frame(width: 58, alignment: .leading)

            Text(captionLine)
                .font(.system(size: 18, weight: recorder.liveCaptionText == nil ? .medium : .semibold))
                .foregroundStyle(recorder.liveCaptionText == nil ? Color.dtLabelSecondary : Color.dtLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(captionLine))
                .accessibilityValue(Text(captionLine))
                .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaption)

            captionControlButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 640, alignment: .leading)
    }

    private func panelBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                LinearGradient(
                    colors: [
                        Color(red: 0.14, green: 0.15, blue: 0.16).opacity(0.88),
                        Color(red: 0.08, green: 0.09, blue: 0.10).opacity(0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
    }

    private var captionControlButtons: some View {
        HStack(spacing: 6) {
            Button(action: onToggleMode) {
                Image(systemName: mode.toggleIcon)
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(PanelIconButtonStyle(size: 24))
            .help(mode.toggleTitle)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(PanelIconButtonStyle(size: 24))
            .help("Hide live captions for this meeting")
            .accessibilityLabel("Hide live captions")
            .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionCloseButton)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            liveBadge

            VStack(alignment: .leading, spacing: 5) {
                Text("Current meeting")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)
                Text(sourceLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 14)

            Text(timeText(recorder.elapsedSeconds))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.dtLabelSecondary)

            captionControlButtons
        }
    }

    private var liveBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(DT.systemRed)
                .frame(width: 8, height: 8)
            Text("Live")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dtLabel)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    liveCaptionLanguageMenu
                    systemAudioChip
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)

            LiveCaptionTextViewport(
                text: captionLine,
                isPlaceholder: recorder.liveCaptionText == nil
            )
            .foregroundStyle(recorder.liveCaptionText == nil ? Color.dtLabelSecondary : Color.dtLabel)
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
        )
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
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.dtLabelTertiary)
            }
            .foregroundStyle(Color.dtLabel)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Live caption language")
        .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingLanguageMenu)
    }

    private var systemAudioChip: some View {
        Text("System audio")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DT.waveformLit)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(.system(size: 22, weight: isPlaceholder ? .medium : .semibold))
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(text))
                        .accessibilityValue(Text(text))
                        .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaption)

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, minHeight: 172, maxHeight: 320, alignment: .topLeading)
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
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }
}
