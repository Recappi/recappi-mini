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
            // First-open default: a caption-first floating overlay, not
            // a document-like window. The transparent top band is reserved
            // for the hover-only header chip so controls can slide above the
            // caption sheet without consuming its readable height.
            return NSSize(width: 560, height: 216)
        case .compact:
            return NSSize(width: 542, height: 94)
        }
    }

    var windowPadding: CGFloat {
        switch self {
        case .expanded:
            return 8
        case .compact:
            return 6
        }
    }

    var contentWidth: CGFloat {
        defaultWindowSize.width - (windowPadding * 2)
    }

    var cornerRadius: CGFloat {
        switch self {
        case .expanded:
            return 16
        case .compact:
            return 14
        }
    }
}

struct LiveCaptionFloatingPanel: View {
    @ObservedObject var recorder: AudioRecorder
    @EnvironmentObject private var config: AppConfig
    @Environment(\.colorScheme) private var colorScheme
    @State private var paneVisibility: LiveCaptionPaneVisibility = .both
    @State private var chromeVisible = false
    let mode: LiveCaptionPanelMode
    let onToggleMode: () -> Void
    let onClose: () -> Void
    let onChromeVisibilityChange: (Bool) -> Void

    struct CompactCaptionRow: Equatable, Identifiable {
        let id: String
        let label: String
        let text: String
        let isPlaceholder: Bool
        let lineLimit: Int
    }

    var body: some View {
        let cornerRadius = mode.cornerRadius
        // `.contentShape` declares the hit-test region so clicks on the
        // transparent corner pixels fall through to the app behind the
        // panel. `LiveCaptionPassthroughHostingView` enforces the same
        // shape at the AppKit layer.
        // No in-tree shadow: NSWindow draws its own shadow outside the
        // frame; doubling them up offsets the visible edge from the
        // NSWindow resize hit zone.
        return Group {
            switch mode {
            case .expanded:
                expandedBody
            case .compact:
                compactBody
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .background {
            if mode == .compact {
                panelBackground(cornerRadius: cornerRadius)
            }
        }
        .focusable(false)
        .recappiSuppressFocusRing()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingPanel)
    }

    private func updateChromeVisibility(_ hovering: Bool) {
        onChromeVisibilityChange(hovering)
        withAnimation(DT.motionAware(DT.ease(DT.Motion.elementPresence))) {
            chromeVisible = hovering
        }
    }

    private var expandedBody: some View {
        // `GeometryReader` propagates the NSWindow's actual content height
        // down to the workspace; without it `.frame(maxHeight: .infinity)`
        // gets clamped by intermediate intrinsic-size frames and the
        // viewport stops short of a user-resized window's bottom edge.
        GeometryReader { proxy in
            // Header is a floating overlay (same model as compact's chrome):
            // the workspace always uses the full height and the header floats on
            // top, shown/hidden purely in SwiftUI via opacity + hit-testing — no
            // dynamic header band that reflows the caption area on hover
            // (peng-xiao 6/3: "header 改成跟 compact 那个模式").
            ZStack(alignment: .topTrailing) {
                liveCaptionWorkspace
                    .frame(height: max(96, proxy.size.height), alignment: .topLeading)
                    .background(panelBackground(cornerRadius: mode.cornerRadius))

                minimalLiveDot
                    .padding(12)
                    .opacity(chromeVisible ? 0 : 1)
                    .scaleEffect(chromeVisible ? 0.88 : 1)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                header
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .opacity(chromeVisible ? 1 : 0)
                    .offset(y: chromeVisible ? 0 : -6)
                    .allowsHitTesting(chromeVisible)
                    .zIndex(2)
            }
            .frame(
                width: max(mode.contentWidth, proxy.size.width),
                height: proxy.size.height,
                alignment: .topLeading
            )
            .modifier(LiveCaptionDebugLayoutBorder(
                color: .red,
                label: "expanded \(Int(proxy.size.width))×\(Int(proxy.size.height))"
            ))
            .animation(DT.motionAware(DT.ease(DT.Motion.elementPresence)), value: chromeVisible)
        }
    }

    private var compactBody: some View {
        // The compact window allows horizontal resize (contentMinSize 542 →
        // maxSize 900 wide). Track the actual width via GeometryReader and size
        // the caption rows to it, instead of pinning a fixed 530 that mismatched
        // the full-width panel background and clipped the capsule corners when
        // the window was wider/narrower (peng-xiao 6/4). Height stays fixed.
        GeometryReader { proxy in
            ZStack(alignment: .trailing) {
                Color.clear
                    .frame(
                        maxWidth: .infinity,
                        minHeight: Self.compactCaptionTwoLineHeight,
                        maxHeight: Self.compactCaptionTwoLineHeight
                    )
                    .overlay(alignment: .leading) {
                        compactCaptionRowsView
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(compactAccessibilityText))
                    .accessibilityValue(Text(compactAccessibilityText))
                    .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaption)

                HStack(alignment: .center, spacing: 7) {
                    compactLiveBadge
                    Text(timeText(recorder.elapsedSeconds))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(glassTextSecondary)
                        .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionElapsedTime)
                    captionControlButtons
                }
                .padding(.leading, 10)
                .background(
                    glassShape(Capsule(style: .continuous))
                )
                .opacity(chromeVisible ? 1 : 0)
                .offset(x: chromeVisible ? 0 : 8)
                .allowsHitTesting(chromeVisible)
                .accessibilityHidden(!chromeVisible)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .onHover(perform: updateChromeVisibility)
    }

    private var compactCaptionRowsView: some View {
        VStack(alignment: .leading, spacing: Self.compactCaptionLineSpacing) {
            ForEach(compactCaptionRows) { row in
                // No ORIGINAL/TRANSLATION text label in compact — it ate a fixed
                // ~96pt column that squeezed the caption (peng-xiao 6/3: "太占
                // 空间", and was the source of the truncated "· ZH"). The caption
                // text now spans the full width. Bilingual rows stay
                // distinguishable by order + the translation row's dimmer weight.
                LiveCaptionCompactTextLine(
                    text: row.text,
                    isPlaceholder: row.isPlaceholder,
                    lineLimit: row.lineLimit
                )
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .frame(height: Self.compactCaptionRowHeight(lineLimit: row.lineLimit), alignment: .bottomLeading)
            }
        }
        // Dark contrast shadow on the dark caption scrim (white text needs a
        // dark halo, not the previous light one) so the compact line stays
        // legible over any backdrop.
        .shadow(color: Color.black.opacity(0.5), radius: 0.8, x: 0, y: 0)
        .frame(maxWidth: .infinity, maxHeight: Self.compactCaptionTwoLineHeight, alignment: .center)
    }

    private func panelBackground(cornerRadius: CGFloat) -> some View {
        glassShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func glassShape<S: Shape>(_ shape: S) -> some View {
        shape
            .fill(glassLegibilityFill)
            .glassEffect(.regular.tint(glassMaterialTint), in: shape)
            .clipShape(shape)
            .compositingGroup()
    }

    private var captionControlButtons: some View {
        HStack(spacing: 5) {
            Button(action: onToggleMode) {
                Image(systemName: mode.toggleIcon)
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(PanelIconButtonStyle(size: 22, backdropAdaptiveForeground: true))
            .focusable(false)
            .recappiSuppressFocusRing()
            .recappiTooltip(mode.toggleTitle)
            .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingPanelModeButton)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(PanelIconButtonStyle(size: 22, backdropAdaptiveForeground: true))
            .focusable(false)
            .recappiSuppressFocusRing()
            .recappiTooltip("Hide live captions for this meeting")
            .accessibilityLabel("Hide live captions")
            .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionCloseButton)
        }
    }

    private var header: some View {
        // Compact-like hover chrome: intrinsic width, pinned top-right, and no
        // source label. The stream identity already lives in the caption panes;
        // keeping it out of this overlay avoids the full-width bar peng-xiao
        // flagged in #205.
        HStack(alignment: .center, spacing: 5) {
            compactLiveBadge
            liveCaptionDisplayControl

            Text(timeText(recorder.elapsedSeconds))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(glassTextSecondary)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionElapsedTime)

            captionControlButtons
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            glassShape(Capsule(style: .continuous))
        )
        .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1.5)
        .onHover(perform: updateChromeVisibility)
        .focusable(false)
        .recappiSuppressFocusRing()
        .accessibilityHidden(!chromeVisible)
        .animation(DT.motionAware(DT.ease(DT.Motion.elementPresence)), value: liveCaptionStatusKind)
            .animation(DT.motionAware(DT.ease(DT.Motion.elementPresence)), value: liveCaptionShowsTranslation)
    }

    private var minimalLiveDot: some View {
        Circle()
            .fill(DT.systemRed)
            .frame(width: 6, height: 6)
            .modifier(PulsingModifier())
            .shadow(color: DT.systemRed.opacity(0.35), radius: 4, x: 0, y: 0)
            .accessibilityHidden(true)
    }

    // MARK: - Live caption connection status (Phase → visual treatment)

    private enum LiveCaptionStatusKind: Equatable {
        case connecting   // .preparing — first connection
        case reconnecting // .reconnecting — session dropped, retry in flight
        case interrupted  // .failed — gave up, user can retry
        case unavailable  // .unavailable — backend can't be used
    }

    private struct LiveCaptionStatusStyle {
        var kind: LiveCaptionStatusKind
        var color: Color
        var label: String        // expanded strip label
        var shortLabel: String   // compact pill label
        var systemImage: String? // nil → calm pulsing dot (in-progress states)
        var actionable: Bool     // tappable → reconnect, and show the Retry control
    }

    private var liveCaptionStatusKind: LiveCaptionStatusKind? {
        switch recorder.liveCaptionStatusPhase {
        case .preparing?: return .connecting
        case .reconnecting?: return .reconnecting
        case .failed?: return .interrupted
        case .unavailable?: return .unavailable
        case .listening?, nil: return nil
        }
    }

    /// Visual treatment for the current connection status, or `nil` while
    /// captions stream normally (`.listening`). Phase-driven — never gated on a
    /// message being present, since Connecting/Reconnecting usually have none.
    private var liveCaptionConnectionStatus: LiveCaptionStatusStyle? {
        guard let kind = liveCaptionStatusKind else { return nil }
        switch kind {
        case .connecting:
            return .init(kind: kind, color: DT.recordingLiveBlue, label: "Connecting…",
                         shortLabel: "Connecting", systemImage: nil, actionable: false)
        case .reconnecting:
            return .init(kind: kind, color: DT.recordingLiveBlue, label: "Reconnecting…",
                         shortLabel: "Reconnecting", systemImage: nil, actionable: false)
        case .interrupted:
            return .init(kind: kind, color: DT.statusWarning, label: "Captions interrupted",
                         shortLabel: "Retry", systemImage: "exclamationmark.triangle.fill",
                         actionable: true)
        case .unavailable:
            return .init(kind: kind, color: DT.systemOrange, label: "Live captions unavailable",
                         shortLabel: "Unavailable", systemImage: "exclamationmark.octagon.fill",
                         actionable: recorder.canReconnectLiveCaptions)
        }
    }

    /// Recorder diagnostic message, surfaced only as tooltip / accessibility
    /// detail. The primary user-facing copy is mapped from the phase above so
    /// it stays consistent and localizable.
    private var liveCaptionStatusDetail: String? {
        let message = recorder.liveCaptionMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        return message?.isEmpty == false ? message : nil
    }

    @ViewBuilder
    private func liveCaptionStatusGlyph(_ style: LiveCaptionStatusStyle, dotSize: CGFloat) -> some View {
        if let symbol = style.systemImage {
            Image(systemName: symbol)
                .font(.system(size: dotSize + 5, weight: .semibold))
                .foregroundStyle(style.color)
        } else {
            Circle()
                .fill(style.color)
                .frame(width: dotSize, height: dotSize)
                .modifier(PulsingModifier())
        }
    }

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(DT.systemRed)
                .frame(width: 6, height: 6)
                .modifier(PulsingModifier())
            Text("Live")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(glassTextPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(DT.systemRed.opacity(0.16))
        )
    }

    /// Compact-panel badge. Swaps the "● Live" pill for a status pill when the
    /// connection is not streaming; the pill is tappable (reconnect) for
    /// actionable states. Stays within the existing pill footprint so the
    /// fixed two-line compact height is never disturbed.
    @ViewBuilder
    private var compactLiveBadge: some View {
        if let style = liveCaptionConnectionStatus {
            let pill = HStack(spacing: 4) {
                liveCaptionStatusGlyph(style, dotSize: 5)
                Text(style.shortLabel)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(glassTextPrimary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(style.color.opacity(0.14))
            )

            if style.actionable {
                Button {
                    recorder.reconnectLiveCaptionsNow()
                } label: {
                    pill
                }
                .buttonStyle(.plain)
                .focusable(false)
                .recappiSuppressFocusRing()
                .recappiTooltip(liveCaptionStatusDetail ?? "Reconnect live captions")
                .accessibilityLabel("Reconnect live captions")
                .accessibilityValue(liveCaptionStatusDetail ?? "")
                .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionReconnectButton)
            } else {
                pill
                    .recappiTooltip(liveCaptionStatusDetail ?? style.label)
                    .accessibilityLabel(style.label)
            }
        } else {
            HStack(spacing: 4) {
                Circle()
                    .fill(DT.systemRed)
                    .frame(width: 5, height: 5)
                    .modifier(PulsingModifier())
                Text("Live")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(glassTextPrimary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(DT.systemRed.opacity(0.12))
            )
        }
    }

    private var verticalHeaderDivider: some View {
        Rectangle()
            .fill(Palette.borderHairline)
            .frame(width: 1, height: 22)
    }

    private var liveCaptionWorkspace: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { proxy in
                liveCaptionPaneGrid
                    .padding(.horizontal, liveCaptionShowsTranslation ? 14 : 18)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.clear)
        )
        .modifier(LiveCaptionDebugLayoutBorder(
            color: .green,
            label: "workspace"
        ))
        .onHover(perform: updateChromeVisibility)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionWorkspace)
    }

    private var liveCaptionDisplayControl: some View {
        Group {
            if liveCaptionShowsTranslation {
                paneVisibilityControls
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 18)
                    .accessibilityLabel("Original captions")
            }
        }
        .foregroundStyle(glassTextSecondary)
        .padding(.horizontal, liveCaptionShowsTranslation ? 3 : 6)
        .padding(.vertical, 2)
        .background(
            glassShape(Capsule(style: .continuous))
        )
        .recappiTooltip("Caption display is chosen before recording starts.")
    }

    private var paneVisibilityControls: some View {
        HStack(spacing: 4) {
            paneStreamToggleButton(
                stream: .caption,
                systemImage: "captions.bubble",
                selectedSystemImage: "captions.bubble.fill",
                title: "Original captions",
                accessibilityIdentifier: AccessibilityIDs.Cloud.currentMeetingCaptionToggleButton
            )
            paneStreamToggleButton(
                stream: .translation,
                systemImage: "translate",
                selectedSystemImage: "translate",
                title: "Translation only",
                accessibilityIdentifier: AccessibilityIDs.Cloud.currentMeetingTranslationToggleButton
            )
        }
        .recappiTooltip("Toggle each live caption stream. At least one stream stays visible.")
    }

    private enum PaneStream {
        case caption
        case translation
    }

    private func paneStreamToggleButton(
        stream: PaneStream,
        systemImage: String,
        selectedSystemImage: String,
        title: String,
        accessibilityIdentifier: String
    ) -> some View {
        let selected = isPaneStreamSelected(stream)
        let canToggle = canTogglePaneStream(stream)
        return Button {
            togglePaneStream(stream)
        } label: {
            Image(systemName: selected ? selectedSystemImage : systemImage)
                .font(.system(size: 10.5, weight: selected ? .bold : .semibold))
                .symbolVariant(selected ? .fill : .none)
                .frame(width: 24, height: 18)
        }
        .buttonStyle(LiveCaptionSegmentedButtonStyle(isSelected: selected))
        .focusable(false)
        .recappiSuppressFocusRing()
        .disabled(!canToggle)
        .recappiTooltip(title)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Shown" : "Hidden")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func isPaneStreamSelected(_ stream: PaneStream) -> Bool {
        let paneVisibility = effectivePaneVisibility
        switch stream {
        case .caption:
            return paneVisibility.showsCaption
        case .translation:
            return paneVisibility.showsTranslation
        }
    }

    private func canTogglePaneStream(_ stream: PaneStream) -> Bool {
        let paneVisibility = effectivePaneVisibility
        let hasCaption = !sourcePaneSegments.isEmpty
        let hasTranslation = !translationOnlySegments.isEmpty
        let hasAnyPaneContent = hasCaption || hasTranslation
        switch stream {
        case .caption:
            guard hasAnyPaneContent else {
                return paneVisibility.showsTranslation || !paneVisibility.showsCaption
            }
            return hasCaption && (paneVisibility.showsTranslation || !paneVisibility.showsCaption)
        case .translation:
            guard hasAnyPaneContent else {
                return paneVisibility.showsCaption || !paneVisibility.showsTranslation
            }
            return hasTranslation && (paneVisibility.showsCaption || !paneVisibility.showsTranslation)
        }
    }

    private func togglePaneStream(_ stream: PaneStream) {
        switch (stream, paneVisibility) {
        case (.caption, .both):
            paneVisibility = .translationOnly
        case (.caption, .translationOnly):
            paneVisibility = .both
        case (.caption, .captionOnly):
            break
        case (.translation, .both):
            paneVisibility = .captionOnly
        case (.translation, .captionOnly):
            paneVisibility = .both
        case (.translation, .translationOnly):
            break
        }
    }

    private var captionPlaceholderText: String {
        Self.originalPlaceholderText
    }

    private var translationPlaceholderText: String {
        Self.translationPlaceholderText
    }

    nonisolated static let originalPlaceholderText = "Listening for original audio"
    nonisolated static let translationPlaceholderText = "Waiting for translation"

    private var sourceStreamText: String {
        if let debugText = ProcessInfo.processInfo.environment["LIVE_CAPTION_DEBUG_TEXT"],
           !debugText.isEmpty {
            return debugText
        }
        return normalizedStreamText(recorder.liveCaptionSegments.map(\.sourceText))
    }

    private var translationStreamText: String {
        let translated = recorder.liveCaptionSegments.compactMap { segment in
            let text = segment.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        return normalizedStreamText(translated)
    }

    private var sourcePaneSegments: [LiveCaptionSegment] {
        paneSegments(
            text: sourceStreamText,
            mode: .source,
            idPrefix: "caption"
        )
    }

    private var translationPaneSegments: [LiveCaptionSegment] {
        paneSegments(
            text: translationStreamText,
            mode: .translation,
            idPrefix: "translation"
        )
    }

    private func normalizedStreamText(_ chunks: [String]) -> String {
        chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func paneSegments(
        text: String,
        mode: LiveCaptionSentenceSplitter.Mode,
        idPrefix: String
    ) -> [LiveCaptionSegment] {
        let sentences = LiveCaptionSentenceSplitter.split(text, mode: mode)
        return sentences.enumerated().map { index, sentence in
            LiveCaptionSegment(
                id: "\(idPrefix)-sentence-\(index)",
                sourceText: sentence,
                translatedText: nil,
                isFinal: index < sentences.count - 1,
                sequence: index
            )
        }
    }

    @ViewBuilder
    private var liveCaptionPaneGrid: some View {
        if liveCaptionShowsTranslation {
            VStack(alignment: .leading, spacing: 8) {
                switch effectivePaneVisibility {
                case .both:
                    GeometryReader { proxy in
                        // Tighter gap (no inner card chrome means we can pull
                        // the columns closer without them blurring together).
                        let gap: CGFloat = 14
                        let sourceWidth = max(160, (proxy.size.width - gap) * 0.57)
                        let translationWidth = max(140, proxy.size.width - gap - sourceWidth)
                        HStack(alignment: .top, spacing: gap) {
                            LiveCaptionStreamPane(
                                title: sourceStreamTitle,
                                systemImage: "captions.bubble",
                                segments: sourcePaneSegments,
                                placeholderText: captionPlaceholderText,
                                isPlaceholder: sourcePaneSegments.isEmpty,
                                errorMessage: nil,
                                showsChrome: true,
                                viewportID: AccessibilityIDs.Cloud.currentMeetingCaptionViewport,
                                textID: AccessibilityIDs.Cloud.currentMeetingCaption
                            )
                            .frame(width: sourceWidth, height: proxy.size.height, alignment: .topLeading)

                            LiveCaptionStreamPane(
                                title: translationStreamTitle,
                                systemImage: "translate",
                                segments: translationOnlySegments,
                                placeholderText: translationPlaceholderText,
                                isPlaceholder: translationOnlySegments.isEmpty,
                                errorMessage: nil,
                                showsChrome: true,
                                viewportID: AccessibilityIDs.Cloud.currentMeetingTranslationViewport,
                                textID: AccessibilityIDs.Cloud.currentMeetingTranslation
                            )
                            .frame(width: translationWidth, height: proxy.size.height, alignment: .topLeading)
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    }
                    .transition(.opacity)
                case .captionOnly:
                    LiveCaptionStreamPane(
                        title: sourceStreamTitle,
                        systemImage: "captions.bubble",
                        segments: sourcePaneSegments,
                        placeholderText: captionPlaceholderText,
                        isPlaceholder: sourcePaneSegments.isEmpty,
                        errorMessage: nil,
                        showsChrome: true,
                        viewportID: AccessibilityIDs.Cloud.currentMeetingCaptionViewport,
                        textID: AccessibilityIDs.Cloud.currentMeetingCaption
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                case .translationOnly:
                    LiveCaptionStreamPane(
                        title: translationStreamTitle,
                        systemImage: "translate",
                        segments: translationOnlySegments,
                        placeholderText: translationPlaceholderText,
                        isPlaceholder: translationOnlySegments.isEmpty,
                        errorMessage: nil,
                        showsChrome: true,
                        viewportID: AccessibilityIDs.Cloud.currentMeetingTranslationViewport,
                        textID: AccessibilityIDs.Cloud.currentMeetingTranslation
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .foregroundStyle(hasLiveCaptionSegments ? glassTextPrimary : glassTextSecondary)
            .animation(DT.motionAware(DT.ease(DT.Motion.elementPresence)), value: paneVisibility)
        } else {
            LiveCaptionStreamPane(
                title: sourceStreamTitle,
                systemImage: "captions.bubble",
                segments: viewportSegments,
                placeholderText: captionLine,
                isPlaceholder: !hasLiveCaptionSegments,
                errorMessage: nil,
                showsChrome: true,
                viewportID: AccessibilityIDs.Cloud.currentMeetingCaptionViewport,
                textID: AccessibilityIDs.Cloud.currentMeetingCaption
            )
            .foregroundStyle(hasLiveCaptionSegments ? glassTextPrimary : glassTextSecondary)
        }
    }

    private var liveCaptionModeStatus: some View {
        HStack(spacing: 5) {
            Image(systemName: liveCaptionShowsTranslation ? "translate" : "text.alignleft")
                .font(.system(size: 10, weight: .semibold))
            Text(liveCaptionModeStatusText)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(glassTextSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.24))
        )
        .recappiTooltip("Caption display is chosen before recording starts.")
    }

    private var liveCaptionShowsTranslation: Bool {
        recorder.activeLiveCaptionConfiguration?.showsTranslation
            ?? config.liveCaptionsBilingualEnabled
    }

    private var liveCaptionDisplayTitle: String {
        guard liveCaptionShowsTranslation else { return "Original" }
        switch effectivePaneVisibility {
        case .both:
            return "Bilingual"
        case .captionOnly:
            return "Original"
        case .translationOnly:
            return liveCaptionTargetLanguageShortTitle
        }
    }

    private var liveCaptionModeStatusText: String {
        guard liveCaptionShowsTranslation else {
            return sourceStreamTitle
        }
        return "\(liveCaptionSourceLanguageShortTitle) → \(liveCaptionTargetLanguageShortTitle)"
    }

    private var sourceStreamTitle: String {
        // Source language is auto-detected, not a user-chosen target, so we do
        // NOT suffix it with a language code — `Original · EN` reads like a
        // "current/locked language" hint. Only the translation side, whose
        // target the user explicitly picks, carries a language suffix.
        Self.streamTitle(role: "Original", languageShortTitle: "")
    }

    private var translationStreamTitle: String {
        Self.streamTitle(role: "Translation", languageShortTitle: liveCaptionTargetLanguageShortTitle)
    }

    private var liveCaptionSourceLanguageShortTitle: String {
        SpeechLanguageOption.option(for: config.cloudLanguage).shortCode
    }

    private var liveCaptionTargetLanguageShortTitle: String {
        let lockedConfig = recorder.activeLiveCaptionConfiguration
        return LiveCaptionTranslationTargetLanguageOption
            .option(for: lockedConfig?.targetLanguage ?? config.liveCaptionsTranslationTargetLanguage)
            .shortTitle
    }

    nonisolated static func streamTitle(role: String, languageShortTitle: String) -> String {
        let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLanguage = languageShortTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRole.isEmpty else { return trimmedLanguage.isEmpty ? "Caption" : trimmedLanguage }
        guard !trimmedLanguage.isEmpty else { return trimmedRole }
        return "\(trimmedRole) · \(trimmedLanguage)"
    }

    private var bilingualViewportSegments: [LiveCaptionSegment] {
        let pairedSegments = recorder.liveCaptionSegments.filter { segment in
            let source = segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let translated = segment.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !source.isEmpty || !translated.isEmpty
        }
        if pairedSegments.contains(where: { $0.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) {
            return pairedSegments
        }

        let maxCount = max(sourcePaneSegments.count, translationPaneSegments.count)
        guard maxCount > 0 else { return [] }
        return (0..<maxCount).map { index in
            let source = index < sourcePaneSegments.count ? sourcePaneSegments[index].sourceText : ""
            let translated = index < translationPaneSegments.count ? translationPaneSegments[index].sourceText : ""
            return LiveCaptionSegment(
                id: "bilingual-line-\(index)",
                sourceText: source,
                translatedText: translated.isEmpty ? nil : translated,
                isFinal: index < maxCount - 1,
                sequence: index
            )
        }
    }

    private var translationOnlySegments: [LiveCaptionSegment] {
        translationPaneSegments.enumerated().map { index, segment in
            LiveCaptionSegment(
                id: "translation-only-\(index)",
                sourceText: segment.sourceText,
                translatedText: nil,
                isFinal: segment.isFinal,
                sequence: segment.sequence
            )
        }
    }

    private var effectivePaneVisibility: LiveCaptionPaneVisibility {
        Self.effectivePaneVisibility(
            requested: paneVisibility,
            hasCaption: !sourcePaneSegments.isEmpty,
            hasTranslation: !translationOnlySegments.isEmpty
        )
    }

    nonisolated static func effectivePaneVisibility(
        requested: LiveCaptionPaneVisibility,
        hasCaption: Bool,
        hasTranslation: Bool
    ) -> LiveCaptionPaneVisibility {
        guard hasCaption || hasTranslation else { return requested }
        if requested.showsCaption, !hasCaption, hasTranslation {
            return .translationOnly
        }
        if requested.showsTranslation, !hasTranslation, hasCaption {
            return .captionOnly
        }
        return requested
    }

    /// True when the recorder has at least one accumulated caption
    /// segment (the placeholder ↔ "real caption" toggle for the panel).
    /// Honors the `LIVE_CAPTION_DEBUG_TEXT` override so debug fixtures
    /// look like real captions to the UI.
    private var hasLiveCaptionSegments: Bool {
        if let debugText = ProcessInfo.processInfo.environment["LIVE_CAPTION_DEBUG_TEXT"],
           !debugText.isEmpty {
            return true
        }
        return !recorder.liveCaptionSegments.isEmpty
    }

    /// Segment list passed into the expanded viewport. Mirrors the
    /// recorder's segments in normal use; substitutes a single
    /// fixture segment when `LIVE_CAPTION_DEBUG_TEXT` is set so the
    /// AppKit text view exercises the same code path under tests.
    private var viewportSegments: [LiveCaptionSegment] {
        if let debugText = ProcessInfo.processInfo.environment["LIVE_CAPTION_DEBUG_TEXT"],
           !debugText.isEmpty {
            return [
                LiveCaptionSegment(
                    id: "debug-fixture",
                    sourceText: debugText,
                    translatedText: nil,
                    isFinal: false,
                    sequence: 0
                )
            ]
        }
        return recorder.liveCaptionSegments
    }

    private var captionLine: String {
        // Debug hook: when `LIVE_CAPTION_DEBUG_TEXT` is set, override the
        // caption with fixture text so layout/scroll can be exercised
        // without a live recording.
        if let debugText = ProcessInfo.processInfo.environment["LIVE_CAPTION_DEBUG_TEXT"],
           !debugText.isEmpty {
            return debugText
        }
        // Natural paragraph breaks: each segment becomes its own line.
        // The expanded NSTextView happily renders these `\n`s; the
        // compact bar applies `lineLimit(2)` and pre-truncation so the
        // joined text still fits in two lines.
        let joined = recorder.liveCaptionSegments
            .map(\.sourceText)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty {
            return joined
        }
        // When the connection is in a status state (connecting / reconnecting /
        // failed / unavailable), `liveCaptionMessage` carries the backend's
        // diagnostic error text. That belongs in the header status strip +
        // retry affordance (see `liveCaptionConnectionStatus`), NOT in the
        // caption body — otherwise a raw server error like
        // "Model gpt-realtime-whisper is a transcription model…" renders as if
        // it were a transcript line. Only fall back to `liveCaptionMessage`
        // for the body while genuinely streaming (no status phase set).
        if liveCaptionStatusKind == nil,
           let message = recorder.liveCaptionMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        // No trailing ellipsis: in some debug paths a U+2026 roundtrips
        // as `â¦` mojibake in screenshots, and the placeholder has no
        // sentence continuation to indicate.
        return "Listening for meeting audio"
    }

    private var compactCaptionRows: [CompactCaptionRow] {
        // Row text is the full caption; the AppKit compact viewport
        // (LiveCaptionCompactTextLine) wraps/clips it to whatever width it's
        // laid out at, so the row model itself is width-independent.
        Self.compactCaptionRows(
            showsTranslation: liveCaptionShowsTranslation,
            paneVisibility: effectivePaneVisibility,
            captionText: captionLine,
            translationText: translationStreamText,
            sourceLanguageShortTitle: liveCaptionSourceLanguageShortTitle,
            targetLanguageShortTitle: liveCaptionTargetLanguageShortTitle
        )
    }

    private var compactAccessibilityText: String {
        compactCaptionRows
            .map { "\($0.label): \($0.text)" }
            .joined(separator: " / ")
    }

    nonisolated static func compactCaptionRows(
        showsTranslation: Bool,
        paneVisibility: LiveCaptionPaneVisibility,
        captionText: String,
        translationText: String,
        sourceLanguageShortTitle: String,
        targetLanguageShortTitle: String
    ) -> [CompactCaptionRow] {
        // Source side shows just "Original" (auto-detected language, no suffix);
        // only the translation side carries its user-chosen target language.
        let sourceLabel = streamTitle(role: "Original", languageShortTitle: "")
        let translationLabel = streamTitle(role: "Translation", languageShortTitle: targetLanguageShortTitle)

        func row(
            id: String,
            label: String,
            sourceText: String,
            placeholderText: String,
            lineLimit: Int
        ) -> CompactCaptionRow {
            let text = compactDisplayText(from: sourceText)
            return CompactCaptionRow(
                id: id,
                label: label,
                text: text.isEmpty ? placeholderText : text,
                isPlaceholder: text.isEmpty,
                lineLimit: lineLimit
            )
        }

        guard showsTranslation else {
            return [
                row(
                    id: "original",
                    label: sourceLabel,
                    sourceText: captionText,
                    placeholderText: originalPlaceholderText,
                    lineLimit: 2
                ),
            ]
        }

        let selectedStreamCount: Int
        switch paneVisibility {
        case .both:
            selectedStreamCount = 2
        case .captionOnly:
            selectedStreamCount = 1
        case .translationOnly:
            selectedStreamCount = 1
        }
        let rowLineLimit = selectedStreamCount == 1 ? 2 : 1
        var rows: [CompactCaptionRow] = []
        if paneVisibility.showsCaption {
            rows.append(
                row(
                    id: "original",
                    label: sourceLabel,
                    sourceText: captionText,
                    placeholderText: originalPlaceholderText,
                    lineLimit: rowLineLimit
                )
            )
        }
        if paneVisibility.showsTranslation {
            rows.append(
                row(
                    id: "translation",
                    label: translationLabel,
                    sourceText: translationText,
                    placeholderText: translationPlaceholderText,
                    lineLimit: rowLineLimit
                )
            )
        }
        return rows.isEmpty
            ? [
                row(
                    id: "original",
                    label: sourceLabel,
                    sourceText: captionText,
                    placeholderText: originalPlaceholderText,
                    lineLimit: 2
                ),
            ]
            : rows
    }

    nonisolated static func compactDisplayText(from text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func compactCaptionRowHeight(lineLimit: Int) -> CGFloat {
        compactCaptionLineHeight * CGFloat(max(1, lineLimit))
    }

    nonisolated static let compactCaptionFontSize: CGFloat = 12.5
    private static let compactCaptionLineSpacing: CGFloat = 1

    /// Height reserved for the compact caption's 2-line slot. Keep this to
    /// exact line-height math: extra breathing room exposes partial hidden
    /// lines when the compact viewport is bottom-anchored to the latest text.
    private static let compactCaptionLineHeight: CGFloat = 15
    private static let compactCaptionTwoLineHeight: CGFloat = (compactCaptionLineHeight * 2) + compactCaptionLineSpacing

    // The live-caption panel is a floating overlay that sits on top of
    // arbitrary backdrops (a dark video, a black meeting window, a bright
    // doc). Unlike the recording pill — which flips its NSAppearance via the
    // backdrop-luminance observer (task #185) — this panel is NOT wired to
    // that machinery, so following the app appearance made dark text vanish
    // over dark content (peng-xiao 6/3 #2). Instead we give it a fixed,
    // backdrop-independent "subtitle" treatment: a dark scrim surface + white
    // text, exactly like the system Live Captions overlay and video subtitle
    // tracks. This guarantees legibility on any backdrop in either appearance.
    private var glassTextPrimary: Color {
        Color.white.opacity(0.96)
    }

    private var glassTextSecondary: Color {
        Color.white.opacity(0.70)
    }

    private var glassLegibilityFill: Color {
        // Opaque-enough dark scrim so white text always reads, regardless of
        // what shows through the glass behind it.
        Color.black.opacity(0.55)
    }

    private var glassMaterialTint: Color {
        Color.black.opacity(0.30)
    }

    private func timeText(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

private struct LiveCaptionStreamPane: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let systemImage: String
    let segments: [LiveCaptionSegment]
    let placeholderText: String
    let isPlaceholder: Bool
    let errorMessage: String?
    let showsChrome: Bool
    let viewportID: String
    let textID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsChrome {
                // Title row drops the icon (the word "Original"/"Translation"
                // already carries the role; the icon was duplicating signal in
                // a tight pane). Two-character language code + middle dot makes
                // the lang affordance scannable without a second tier of chip.
                HStack(spacing: 0) {
                    Text(title)
                        .font(.system(size: 9.5, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(streamLabelColor)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            LiveCaptionTextViewport(
                segments: segments,
                placeholderText: placeholderText,
                isPlaceholder: isPlaceholder,
                errorMessage: errorMessage,
                viewportID: viewportID,
                textID: textID
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Each pane sits directly on the panel's glass surface — no nested
        // card chrome. peng-xiao 5/28 11:24: "不要卡片套卡片". The columns
        // are visually separated by the parent HStack's gap, not by their
        // own backgrounds.
        .animation(DT.motionAware(DT.ease(DT.Motion.elementPresence)), value: showsChrome)
    }

    private var streamLabelColor: Color {
        // Stream label ("Original" / "Translation · ZH") sits on the same dark
        // caption scrim, so it stays a muted white in both appearances rather
        // than flipping to dark (which vanished on the scrim).
        Color.white.opacity(0.6)
    }
}

private struct LiveCaptionTextViewport: View {
    @Environment(\.colorScheme) private var colorScheme
    let segments: [LiveCaptionSegment]
    let placeholderText: String
    let isPlaceholder: Bool
    let errorMessage: String?
    let viewportID: String
    let textID: String

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if errorMessage != nil, isPlaceholder {
                    Color.clear
                } else {
                    LiveCaptionAppKitTextView(
                        segments: segments,
                        placeholderText: placeholderText,
                        isPlaceholder: isPlaceholder,
                        colorScheme: colorScheme,
                        viewportID: viewportID,
                        textID: textID
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }

                if let errorMessage {
                    LiveCaptionErrorBanner(message: errorMessage)
                        .padding(.top, 2)
                        .padding(.trailing, 2)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .accessibilityIdentifier(viewportID)
        .accessibilityLabel(Text(displayedAccessibilityLabel))
        .accessibilityValue(Text(displayedAccessibilityLabel))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(LiveCaptionDebugLayoutBorder(
            color: DT.appAccent,
            label: "viewport"
        ))
    }

    private var displayedAccessibilityLabel: String {
        if let errorMessage { return errorMessage }
        if isPlaceholder { return placeholderText }
        return segments
            .map { segment in
                if let translated = segment.translatedText, !translated.isEmpty {
                    return "\(segment.sourceText)\n\(translated)"
                }
                return segment.sourceText
            }
            .joined(separator: "\n")
    }
}

private struct LiveCaptionErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
        }
        .foregroundStyle(Color.white.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        )
    }
}

private struct LiveCaptionCompactTextLine: NSViewRepresentable {
    let text: String
    let isPlaceholder: Bool
    let lineLimit: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.lineBreakMode = .byWordWrapping

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.apply(text: text, isPlaceholder: isPlaceholder)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.apply(text: text, isPlaceholder: isPlaceholder)
        context.coordinator.scrollToBottom()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        private var appliedText = ""
        private var appliedPlaceholder = false
        private var lastTargetY: CGFloat?

        func apply(text: String, isPlaceholder: Bool) {
            guard let textView else { return }
            if text == appliedText && isPlaceholder == appliedPlaceholder {
                // Re-layout pass (e.g. resize), not new speech — keep pinned to
                // the bottom without animating.
                scrollToBottom(animated: false)
                return
            }
            // New caption content arrived: animate the upward scroll so the
            // latest line slides into view instead of hard-jumping — but only
            // once there's prior content (don't animate the first fill).
            let animate = !isPlaceholder && !appliedText.isEmpty

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 0
            paragraph.paragraphSpacing = 0
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.alignment = .left

            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(isPlaceholder ? 0.45 : 0.6)
            shadow.shadowBlurRadius = 0.8
            shadow.shadowOffset = .zero

            textView.textStorage?.setAttributedString(NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: LiveCaptionFloatingPanel.compactCaptionFontSize, weight: isPlaceholder ? .medium : .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(isPlaceholder ? 0.70 : 0.96),
                    .paragraphStyle: paragraph,
                    .shadow: shadow,
                ]
            ))
            appliedText = text
            appliedPlaceholder = isPlaceholder
            scrollToBottom(animated: animate)
        }

        func scrollToBottom(animated: Bool = false) {
            guard let scrollView,
                  let docView = scrollView.documentView,
                  let textView = textView,
                  let textContainer = textView.textContainer else { return }
            textView.layoutManager?.ensureLayout(for: textContainer)
            let usedRect = textView.layoutManager?.usedRect(for: textContainer) ?? .zero
            var frame = textView.frame
            frame.size.width = scrollView.contentView.bounds.width
            frame.size.height = max(scrollView.contentView.bounds.height, ceil(usedRect.height))
            textView.frame = frame
            let targetY = max(0, docView.frame.height - scrollView.contentView.bounds.height)
            let clip = scrollView.contentView

            // Only animate a real downward advance (new content pushing the
            // latest line up). First paint, no-op re-scrolls, and any upward
            // jump fall back to an instant set so nothing drifts or stutters.
            let shouldAnimate = animated
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                && lastTargetY.map { targetY - $0 > 0.5 } == true
            lastTargetY = targetY

            guard shouldAnimate else {
                clip.scroll(to: NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(clip)
                return
            }

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(clip)
            }
        }
    }
}

private struct LiveCaptionSegmentedButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        // The panel surface is a fixed dark scrim (see glassLegibilityFill), so
        // both selected and unselected segments use light foregrounds — dark
        // text/fills vanished on the scrim (peng-xiao 6/3 #2 header contrast).
        configuration.label
            .foregroundStyle(isSelected ? Color.white.opacity(0.96) : Color.white.opacity(0.55))
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isSelected
                            ? Color.white.opacity(0.20)
                            : (configuration.isPressed ? Color.white.opacity(0.10) : Color.clear)
                    )
            )
            .contentShape(Capsule(style: .continuous))
    }
}

/// AppKit-backed live caption viewport. SwiftUI `Text` re-lays out the
/// whole string on every delta; NSTextStorage handles incremental
/// append/replace cheaply and gives native selection/copy/find for free.
///
/// Follow-tail: if the visible region was at (or near) the bottom before
/// a text update, the coordinator scrolls back to the bottom after the
/// update. If the user has manually scrolled up, the viewport stays put
/// until they scroll back down.
private struct LiveCaptionAppKitTextView: NSViewRepresentable {
    let segments: [LiveCaptionSegment]
    let placeholderText: String
    let isPlaceholder: Bool
    let colorScheme: ColorScheme
    let viewportID: String
    let textID: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // NSTextView's `lineFragmentPadding` defaults to 5pt — it nudges
        // text in from the container's leading edge. With the SwiftUI
        // title row sitting at x=0 of the same column, that default
        // produced a visible misalignment (caption body indented past
        // the `ORIGINAL · EN` label). Zero it so the body and title
        // share the same leading edge.
        textView.textContainer?.lineFragmentPadding = 0
        textView.linkTextAttributes = [:]
        // Carry the SwiftUI accessibilityIdentifier through to the
        // AppKit text view so XCUITest can still find the caption AX
        // element. SwiftUI does not propagate the identifier into a
        // wrapped NSViewRepresentable, so we set it here directly. The
        // scroll view exposes the viewport identifier; the text view
        // exposes the caption text identifier (the same constant the
        // SwiftUI compact body uses, kept in sync via AccessibilityIDs).
        scrollView.setAccessibilityIdentifier(viewportID)
        textView.setAccessibilityIdentifier(textID)
        scrollView.documentView = textView

        // Watch the NSClipView so we know when the user scrolls away
        // from the bottom (and back).
        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.applySegments(
            segments,
            placeholderText: placeholderText,
            isPlaceholder: isPlaceholder,
            colorScheme: colorScheme,
            scrollToBottom: true
        )
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let shouldScroll = context.coordinator.shouldFollowTail
        context.coordinator.applySegments(
            segments,
            placeholderText: placeholderText,
            isPlaceholder: isPlaceholder,
            colorScheme: colorScheme,
            scrollToBottom: shouldScroll
        )
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        /// Tracks whether the visible region currently includes the
        /// bottom edge. Defaults to `true` so the first text update
        /// scrolls to the bottom.
        var shouldFollowTail: Bool = true
        private var appliedText: String = ""
        private var appliedPlaceholder: Bool = false

        @objc func scrollDidChange(_ notification: Notification) {
            guard let scrollView = scrollView,
                  let docView = scrollView.documentView else { return }
            let visible = scrollView.contentView.documentVisibleRect
            let docHeight = docView.frame.height
            // Slack avoids flickering follow-tail off on a single
            // wheel notch — anything within 5% of the viewport height
            // (min 8pt) still counts as "near the bottom".
            let slack: CGFloat = max(8, visible.height * 0.05)
            let visibleBottom = visible.origin.y + visible.height
            shouldFollowTail = visibleBottom + slack >= docHeight
        }

        func applySegments(
            _ segments: [LiveCaptionSegment],
            placeholderText: String,
            isPlaceholder: Bool,
            colorScheme: ColorScheme,
            scrollToBottom: Bool
        ) {
            guard let textView = textView, let storage = textView.textStorage else { return }

            // Bilingual mode is detected per-update from segment payload:
            // any non-empty `translatedText` triggers attributed-string
            // rendering with secondary-color translation rows. Pure-
            // transcription updates fall through to the common-prefix
            // incremental path so streaming deltas don't reflow the
            // whole transcript on every glyph.
            let isBilingual = segments.contains { ($0.translatedText?.isEmpty == false) }

            if isPlaceholder {
                applyFlatText(placeholderText, isPlaceholder: true, colorScheme: colorScheme, scrollToBottom: scrollToBottom, storage: storage)
                return
            }

            if isBilingual {
                applyBilingualSegments(segments, colorScheme: colorScheme, scrollToBottom: scrollToBottom, storage: storage)
                return
            }

            let flat = segments.map(\.sourceText).joined(separator: "\n")
            applyFlatText(flat, isPlaceholder: false, colorScheme: colorScheme, scrollToBottom: scrollToBottom, storage: storage)
        }

        private func applyFlatText(
            _ text: String,
            isPlaceholder: Bool,
            colorScheme: ColorScheme,
            scrollToBottom: Bool,
            storage: NSTextStorage
        ) {
            if text == appliedText && isPlaceholder == appliedPlaceholder {
                if scrollToBottom { scrollViewToBottom() }
                return
            }

            let attrs = Self.flatAttributes(isPlaceholder: isPlaceholder, colorScheme: colorScheme)

            if text == appliedText {
                storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
                appliedPlaceholder = isPlaceholder
                if scrollToBottom { scrollViewToBottom() }
                return
            }

            // Common-prefix incremental update: append-only deltas
            // (streaming captions) replace just the suffix so the layout
            // manager re-flows only the new tail. Anything else (full
            // rewrite, shrink) falls back to a full set.
            let oldNS = appliedText as NSString
            let newNS = text as NSString
            let commonPrefix = Self.commonPrefixLength(oldNS, newNS)
            if commonPrefix > 0 && commonPrefix == oldNS.length {
                let appendedRange = NSRange(location: commonPrefix, length: newNS.length - commonPrefix)
                let appended = newNS.substring(with: appendedRange)
                storage.append(NSAttributedString(string: appended, attributes: attrs))
            } else if commonPrefix > 0 {
                let replaceRange = NSRange(location: commonPrefix, length: oldNS.length - commonPrefix)
                let replacement = newNS.substring(from: commonPrefix)
                storage.replaceCharacters(in: replaceRange, with: NSAttributedString(string: replacement, attributes: attrs))
            } else {
                storage.setAttributedString(NSAttributedString(string: text, attributes: attrs))
            }

            if isPlaceholder != appliedPlaceholder {
                storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
            }

            appliedText = text
            appliedPlaceholder = isPlaceholder

            if scrollToBottom {
                scrollViewToBottom()
            }
        }

        /// Bilingual full-rebuild: each segment becomes two rows —
        /// source line in primary text color, translation line in
        /// secondary text color (slightly smaller). Segments are
        /// separated by a blank line so the eye groups source ↔
        /// translation pairs together. We don't use the common-prefix
        /// optimization here: the alternating attribute runs make
        /// incremental update brittle, and bilingual streams are short
        /// enough (one segment ≈ a sentence) that a per-update rebuild
        /// is cheap.
        private func applyBilingualSegments(
            _ segments: [LiveCaptionSegment],
            colorScheme: ColorScheme,
            scrollToBottom: Bool,
            storage: NSTextStorage
        ) {
            let attributed = NSMutableAttributedString()
            let sourceAttrs = Self.flatAttributes(isPlaceholder: false, colorScheme: colorScheme)
            let translationAttrs = Self.translationAttributes(colorScheme: colorScheme)

            for (index, segment) in segments.enumerated() {
                if index > 0 {
                    attributed.append(NSAttributedString(string: "\n", attributes: sourceAttrs))
                }
                attributed.append(NSAttributedString(string: segment.sourceText, attributes: sourceAttrs))
                if let translated = segment.translatedText, !translated.isEmpty {
                    attributed.append(NSAttributedString(string: "\n", attributes: sourceAttrs))
                    attributed.append(NSAttributedString(string: translated, attributes: translationAttrs))
                }
            }

            if attributed.string == appliedText && !appliedPlaceholder {
                return
            }

            storage.setAttributedString(attributed)
            // Snapshot the joined text so a switch back to monolingual
            // (e.g. user toggles bilingual off mid-session) doesn't see
            // a stale `appliedText` and skip the next refresh.
            appliedText = attributed.string
            appliedPlaceholder = false

            if scrollToBottom {
                scrollViewToBottom()
            }
        }

        private static func flatAttributes(isPlaceholder: Bool, colorScheme: ColorScheme) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = 6
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.alignment = .left
            // Fixed subtitle treatment: white text + dark shadow regardless of
            // appearance, so captions stay legible on any backdrop (see the
            // glassTextPrimary note). Matches the panel's dark scrim surface.
            let foreground = NSColor.white.withAlphaComponent(isPlaceholder ? 0.66 : 0.96)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(isPlaceholder ? 0.45 : 0.6)
            shadow.shadowBlurRadius = 1.0
            shadow.shadowOffset = .zero
            return [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: foreground,
                .paragraphStyle: paragraph,
                .shadow: shadow,
            ]
        }

        private static func translationAttributes(colorScheme: ColorScheme) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = 6
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.alignment = .left
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 0.9
            shadow.shadowOffset = .zero
            return [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.78),
                .paragraphStyle: paragraph,
                .shadow: shadow,
            ]
        }

        private static func commonPrefixLength(_ a: NSString, _ b: NSString) -> Int {
            let limit = min(a.length, b.length)
            var i = 0
            while i < limit && a.character(at: i) == b.character(at: i) {
                i += 1
            }
            return i
        }

        private func scrollViewToBottom() {
            guard let scrollView = scrollView,
                  let docView = scrollView.documentView,
                  let textView = textView,
                  let textContainer = textView.textContainer else { return }
            textView.layoutManager?.ensureLayout(for: textContainer)
            let docHeight = docView.frame.height
            let visibleHeight = scrollView.contentView.bounds.height
            let targetY = max(0, docHeight - visibleHeight)
            let currentY = scrollView.contentView.bounds.origin.y
            guard abs(currentY - targetY) > 1 else {
                shouldFollowTail = true
                return
            }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            shouldFollowTail = true
        }
    }
}

/// Stamps a colored border + size label on the wrapped view so we can
/// see which SwiftUI layer is failing to fill the NSWindow bounds.
/// Enabled via `LIVE_CAPTION_DEBUG_LAYOUT=1` env var or the
/// `live_caption_debug_layout` UserDefaults key.
private struct LiveCaptionDebugLayoutBorder: ViewModifier {
    let color: Color
    let label: String

    func body(content: Content) -> some View {
        if LiveCaptionDebugLayout.isEnabled {
            content
                .overlay(alignment: .topLeading) {
                    Text(label)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(color.opacity(0.85))
                }
                .overlay(
                    Rectangle().stroke(color.opacity(0.85), lineWidth: 1.5)
                )
        } else {
            content
        }
    }
}

private enum LiveCaptionDebugLayout {
    static let isEnabled: Bool = {
        if ProcessInfo.processInfo.environment["LIVE_CAPTION_DEBUG_LAYOUT"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "live_caption_debug_layout")
    }()
}
