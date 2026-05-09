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
            return NSSize(width: 542, height: 420)
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
                    Text(compactCaptionLine)
                        .font(.system(size: 15, weight: recorder.liveCaptionText == nil ? .medium : .semibold))
                        .foregroundStyle(recorder.liveCaptionText == nil ? Color.dtLabelSecondary : Color.dtLabel)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(compactCaptionLine))
                .accessibilityValue(Text(compactCaptionLine))
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
        // Debug hook: when `LIVE_CAPTION_DEBUG_TEXT` is set, override the
        // caption with fixture text so layout/scroll can be exercised
        // without a live recording.
        if let debugText = ProcessInfo.processInfo.environment["LIVE_CAPTION_DEBUG_TEXT"],
           !debugText.isEmpty {
            return debugText
        }
        if let text = recorder.liveCaptionText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
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

private struct LiveCaptionTextViewport: View {
    let text: String
    let isPlaceholder: Bool

    var body: some View {
        LiveCaptionAppKitTextView(text: text, isPlaceholder: isPlaceholder)
            .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionViewport)
            .accessibilityLabel(Text(text))
            .accessibilityValue(Text(text))
            .modifier(LiveCaptionDebugLayoutBorder(
                color: .blue,
                label: "viewport"
            ))
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
    let text: String
    let isPlaceholder: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed

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
        scrollView.setAccessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionViewport)
        textView.setAccessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaption)
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

        context.coordinator.applyText(text, isPlaceholder: isPlaceholder, scrollToBottom: true)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let shouldScroll = context.coordinator.shouldFollowTail
        context.coordinator.applyText(text, isPlaceholder: isPlaceholder, scrollToBottom: shouldScroll)
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

        func applyText(_ text: String, isPlaceholder: Bool, scrollToBottom: Bool) {
            guard let textView = textView, let storage = textView.textStorage else { return }
            if text == appliedText && isPlaceholder == appliedPlaceholder {
                if scrollToBottom { scrollViewToBottom() }
                return
            }

            let attrs = Self.attributes(isPlaceholder: isPlaceholder)

            // Placeholder flag flipped only: restyle in place so
            // NSTextView keeps its existing glyph cache.
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

            // Restyle anything we kept so a placeholder flip applies
            // to the previously rendered range too.
            if isPlaceholder != appliedPlaceholder {
                storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
            }

            appliedText = text
            appliedPlaceholder = isPlaceholder

            if scrollToBottom {
                DispatchQueue.main.async { [weak self] in
                    self?.scrollViewToBottom()
                }
            }
        }

        private static func attributes(isPlaceholder: Bool) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.alignment = .left
            let foreground: NSColor = isPlaceholder
                ? NSColor.secondaryLabelColor
                : NSColor.labelColor
            return [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: foreground,
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
                  let docView = scrollView.documentView else { return }
            let docHeight = docView.frame.height
            let visibleHeight = scrollView.contentView.bounds.height
            let targetY = max(0, docHeight - visibleHeight)
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
