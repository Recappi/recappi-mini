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
            // First-open default. The user can drag the panel taller
            // for more caption history; we no longer pin the SwiftUI
            // tree to a hard-coded height so the resize sticks.
            return NSSize(width: 560, height: 420)
        case .compact:
            return NSSize(width: 542, height: 104)
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
    @State private var paneVisibility: LiveCaptionPaneVisibility = .both
    let mode: LiveCaptionPanelMode
    let onToggleMode: () -> Void
    let onClose: () -> Void

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
        .background(panelBackground(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Palette.borderSubtle, lineWidth: 0.6)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingPanel)
    }

    private var expandedBody: some View {
        // `GeometryReader` propagates the NSWindow's actual content height
        // down to the workspace; without it `.frame(maxHeight: .infinity)`
        // gets clamped by intermediate intrinsic-size frames and the
        // viewport stops short of a user-resized window's bottom edge.
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                header

                liveCaptionWorkspace
            }
            .padding(12)
            .frame(
                width: max(mode.contentWidth, proxy.size.width),
                height: proxy.size.height,
                alignment: .topLeading
            )
            .modifier(LiveCaptionDebugLayoutBorder(
                color: .red,
                label: "expanded \(Int(proxy.size.width))×\(Int(proxy.size.height))"
            ))
        }
    }

    private var compactBody: some View {
        // Compact layout: caption fills the LEFT in a fixed two-line
        // slot; recording dot + elapsed time + expand/close cluster on
        // the RIGHT. The slot's height is pinned by the outer
        // `.frame(height:)` (NOT `lineLimit(2, reservesSpace: true)`)
        // because `Alignment.leading` is (h: leading, v: center), so a
        // 1-line caption sits visually centered inside the slot instead
        // of hugging the top edge.
        HStack(alignment: .center, spacing: 10) {
            // Caption slot — a transparent `Color.clear` that owns the
            // **full** middle-lane rectangle (so SwiftUI accessibility
            // and XCUITest frames measure the slot, not the wrapped
            // text-glyph bounding box) with the visible Text rendered
            // as an overlay. The Text uses `.lineLimit(2)` and wraps
            // freely; the slot's own height is pinned to two lines so
            // the bar stays a stable size whether the caption is one
            // or two lines, and `Alignment.leading` (h: leading,
            // v: center) keeps a short caption visually centered.
            Color.clear
                .frame(
                    maxWidth: .infinity,
                    minHeight: Self.compactCaptionTwoLineHeight,
                    maxHeight: Self.compactCaptionTwoLineHeight
                )
                .overlay(alignment: .leading) {
                    Text(compactDisplayLine)
                        .font(.system(size: 15, weight: hasLiveCaptionSegments ? .semibold : .medium))
                        .foregroundStyle(hasLiveCaptionSegments ? Color.dtLabel : Color.dtLabelSecondary)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(compactDisplayLine))
                .accessibilityValue(Text(compactDisplayLine))
                .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaption)

            HStack(alignment: .center, spacing: 6) {
                Circle()
                    .fill(DT.systemRed)
                    .frame(width: 6, height: 6)
                    .modifier(PulsingModifier())
                Text(timeText(recorder.elapsedSeconds))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.dtLabelSecondary)
                    .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionElapsedTime)
                captionControlButtons
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // Pin to nominal content width: the compact NSWindow is fixed to
        // `defaultWindowSize`, so `.infinity` here would blow the
        // SwiftUI fittingSize up to the host's available width.
        .frame(width: mode.contentWidth, alignment: .leading)
    }

    private func panelBackground(cornerRadius: CGFloat) -> some View {
        // `.regularMaterial` adapts to the system appearance; the tinted
        // overlay gives the panel its slightly lifted look in both
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

            if let liveCaptionErrorMessage {
                liveCaptionErrorIndicator(message: liveCaptionErrorMessage)
            }

            if liveCaptionShowsTranslation {
                paneVisibilityControls
            }

            liveCaptionModeStatus

            captionControlButtons
        }
    }

    private func liveCaptionErrorIndicator(message: String) -> some View {
        Button {
            let alert = NSAlert()
            alert.messageText = "Live captions"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DT.statusWarning)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(message)
        .accessibilityLabel("Live caption error")
        .accessibilityValue(message)
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
            GeometryReader { proxy in
                liveCaptionPaneGrid
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.controlFillHover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Palette.borderHairline, lineWidth: 0.6)
        )
        .modifier(LiveCaptionDebugLayoutBorder(
            color: .green,
            label: "workspace"
        ))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionWorkspace)
    }

    private var paneVisibilityControls: some View {
        HStack(spacing: 4) {
            Button {
                togglePane(.captionOnly)
            } label: {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(LiveCaptionSegmentedButtonStyle(isSelected: paneVisibility.showsCaption))
            .disabled(paneVisibility == .captionOnly)
            .help("Caption only")
            .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionToggleButton)

            Button {
                togglePane(.translationOnly)
            } label: {
                Image(systemName: "translate")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(LiveCaptionSegmentedButtonStyle(isSelected: paneVisibility.showsTranslation))
            .disabled(paneVisibility == .translationOnly)
            .help("Translation only")
            .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingTranslationToggleButton)
        }
        .padding(2)
        .background(
            Capsule(style: .continuous)
                .fill(Palette.controlFillHover)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Palette.borderHairline, lineWidth: 0.6)
        )
        .help("Show or hide each live caption stream. At least one panel stays visible.")
    }

    private func togglePane(_ pane: LiveCaptionPaneVisibility) {
        switch (pane, paneVisibility) {
        case (.captionOnly, .both):
            paneVisibility = .translationOnly
        case (.captionOnly, .translationOnly):
            paneVisibility = .both
        case (.translationOnly, .both):
            paneVisibility = .captionOnly
        case (.translationOnly, .captionOnly):
            paneVisibility = .both
        default:
            break
        }
    }

    private var captionPlaceholderText: String {
        "正在听..."
    }

    private var translationPlaceholderText: String {
        "正在听..."
    }

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
            HStack(alignment: .top, spacing: 10) {
                if paneVisibility.showsCaption {
                    LiveCaptionStreamPane(
                        title: "Caption",
                        systemImage: "captions.bubble",
                        segments: sourcePaneSegments,
                        placeholderText: captionPlaceholderText,
                        isPlaceholder: paneVisibility != .both && sourcePaneSegments.isEmpty,
                        errorMessage: nil,
                        viewportID: AccessibilityIDs.Cloud.currentMeetingCaptionViewport,
                        textID: AccessibilityIDs.Cloud.currentMeetingCaption
                    )
                }
                if paneVisibility.showsTranslation {
                    LiveCaptionStreamPane(
                        title: "Translation",
                        systemImage: "translate",
                        segments: translationPaneSegments,
                        placeholderText: translationPlaceholderText,
                        isPlaceholder: paneVisibility != .both && translationPaneSegments.isEmpty,
                        errorMessage: nil,
                        viewportID: AccessibilityIDs.Cloud.currentMeetingTranslationViewport,
                        textID: AccessibilityIDs.Cloud.currentMeetingTranslation
                    )
                }
            }
            .foregroundStyle(hasLiveCaptionSegments ? Color.dtLabel : Color.dtLabelSecondary)
        } else {
            LiveCaptionTextViewport(
                segments: viewportSegments,
                placeholderText: captionLine,
                isPlaceholder: !hasLiveCaptionSegments,
                errorMessage: nil,
                viewportID: AccessibilityIDs.Cloud.currentMeetingCaptionViewport,
                textID: AccessibilityIDs.Cloud.currentMeetingCaption
            )
            .foregroundStyle(hasLiveCaptionSegments ? Color.dtLabel : Color.dtLabelSecondary)
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
        .foregroundStyle(Color.dtLabelSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Palette.controlFillHover)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Palette.borderHairline, lineWidth: 0.6)
        )
        .help("Caption display is chosen before recording starts.")
    }

    private var liveCaptionShowsTranslation: Bool {
        recorder.activeLiveCaptionConfiguration?.showsTranslation
            ?? config.liveCaptionsBilingualEnabled
    }

    private var liveCaptionModeStatusText: String {
        let lockedConfig = recorder.activeLiveCaptionConfiguration
        guard liveCaptionShowsTranslation else {
            return "Original"
        }
        let target = LiveCaptionTranslationTargetLanguageOption
            .option(for: lockedConfig?.targetLanguage ?? config.liveCaptionsTranslationTargetLanguage)
            .shortTitle
        return "Caption + \(target)"
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

    private var liveCaptionErrorMessage: String? {
        guard recorder.liveCaptionStatusPhase == .failed || recorder.liveCaptionStatusPhase == .unavailable else {
            return nil
        }
        let message = recorder.liveCaptionMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        return message?.isEmpty == false ? message : nil
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
        if let message = recorder.liveCaptionMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        // No trailing ellipsis: in some debug paths a U+2026 roundtrips
        // as `â¦` mojibake in screenshots, and the placeholder has no
        // sentence continuation to indicate.
        return "Listening for meeting audio"
    }

    /// Caption fragment shown in compact mode. Pre-truncated to fit
    /// cleanly in two visual lines so SwiftUI's `lineLimit(2)` never
    /// has to insert a "…" indicator. The expanded panel renders the
    /// full transcript via `LiveCaptionAppKitTextView`.
    private var compactCaptionLine: String {
        let normalized = captionLine
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let containsCJK = normalized.contains(where: \.isCompactCJK)
        let budget = containsCJK
            ? Self.compactCaptionMaxCJKCharacters
            : Self.compactCaptionMaxASCIICharacters
        guard normalized.count > budget else { return normalized }
        let tail = String(normalized.suffix(budget))
        // CJK has no word breaks worth respecting — return the raw tail.
        if containsCJK {
            return tail
        }
        // ASCII / mixed: advance to the next whitespace so the visible
        // tail starts on a fresh word instead of mid-token. Fall back
        // to the raw cut for a single very long token.
        guard let firstSpace = tail.firstIndex(where: \.isWhitespace) else { return tail }
        let afterSpace = tail.index(after: firstSpace)
        guard afterSpace < tail.endIndex else { return tail }
        return String(tail[afterSpace...])
    }

    private var compactDisplayLine: String {
        guard liveCaptionShowsTranslation, !paneVisibility.showsCaption else {
            return compactCaptionLine
        }
        let normalized = translationStreamText
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return "Waiting for translation" }
        let containsCJK = normalized.contains(where: \.isCompactCJK)
        let budget = containsCJK
            ? Self.compactCaptionMaxCJKCharacters
            : Self.compactCaptionMaxASCIICharacters
        guard normalized.count > budget else { return normalized }
        let tail = String(normalized.suffix(budget))
        if containsCJK { return tail }
        guard let firstSpace = tail.firstIndex(where: \.isWhitespace) else { return tail }
        let afterSpace = tail.index(after: firstSpace)
        guard afterSpace < tail.endIndex else { return tail }
        return String(tail[afterSpace...])
    }

    private static let compactCaptionMaxASCIICharacters: Int = 90
    private static let compactCaptionMaxCJKCharacters: Int = 44

    /// Height reserved for the compact caption's 2-line slot. System
    /// 15pt + lineSpacing 2 measures ~37.7pt for two lines; rounding to
    /// 44 gives ascender clearance and ~13pt of breathing room that
    /// vertically centers 1-line content inside the slot.
    private static let compactCaptionTwoLineHeight: CGFloat = 44

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

private struct LiveCaptionStreamPane: View {
    let title: String
    let systemImage: String
    let segments: [LiveCaptionSegment]
    let placeholderText: String
    let isPlaceholder: Bool
    let errorMessage: String?
    let viewportID: String
    let textID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
    }
}

private struct LiveCaptionTextViewport: View {
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
            color: .blue,
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
        .foregroundStyle(Color.dtLabelSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.controlFillPress)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.borderHairline, lineWidth: 0.6)
        )
    }
}

private struct LiveCaptionSegmentedButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.dtLabel : Color.dtLabelSecondary)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isSelected
                            ? DT.waveformLit.opacity(0.16)
                            : (configuration.isPressed ? Palette.controlFillHover : Color.clear)
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
                applyFlatText(placeholderText, isPlaceholder: true, scrollToBottom: scrollToBottom, storage: storage)
                return
            }

            if isBilingual {
                applyBilingualSegments(segments, scrollToBottom: scrollToBottom, storage: storage)
                return
            }

            let flat = segments.map(\.sourceText).joined(separator: "\n")
            applyFlatText(flat, isPlaceholder: false, scrollToBottom: scrollToBottom, storage: storage)
        }

        private func applyFlatText(
            _ text: String,
            isPlaceholder: Bool,
            scrollToBottom: Bool,
            storage: NSTextStorage
        ) {
            if text == appliedText && isPlaceholder == appliedPlaceholder {
                if scrollToBottom { scrollViewToBottom() }
                return
            }

            let attrs = Self.flatAttributes(isPlaceholder: isPlaceholder)

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
            scrollToBottom: Bool,
            storage: NSTextStorage
        ) {
            let attributed = NSMutableAttributedString()
            let sourceAttrs = Self.flatAttributes(isPlaceholder: false)
            let translationAttrs = Self.translationAttributes()

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

        private static func flatAttributes(isPlaceholder: Bool) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = 6
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.alignment = .left
            let foreground: NSColor = isPlaceholder
                ? NSColor.secondaryLabelColor
                : NSColor.labelColor
            return [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: foreground,
                .paragraphStyle: paragraph,
            ]
        }

        private static func translationAttributes() -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = 6
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.alignment = .left
            return [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
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

private extension Character {
    /// True for dense CJK glyphs (Chinese, Japanese kana, Korean Hangul)
    /// so `compactCaptionLine` can switch to a tighter character budget.
    var isCompactCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x3040...0x30FF).contains(scalar.value) ||
                (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}
