import AppKit
import Combine
import SwiftUI

/// Self-drawn floating tooltip that escapes the floating panel's clipShape
/// by rendering into a separate borderless `NSPanel`. Tahoe's native tooltip
/// works mechanically but peng-xiao 5/28 17:36 flagged it as visually off
/// for the recording panel's aesthetic; this component renders a glass pill
/// matching the host panel chrome.
///
/// Two behaviors peng-xiao explicitly asked for (5/28 17:43):
/// 1. Position is strictly clamped to the visible screen rect (the panel
///    sits at the top-right of the display, so naive "above the anchor"
///    placement is regularly cropped by the menu bar / screen edge).
/// 2. When the user moves from one tooltipped button to another while a
///    tooltip is already showing, a fixed transparent carrier window is
///    reused. The glass pill inside that carrier morphs its position/width
///    and cross-fades text instead of moving/resizing the NSWindow itself.
///
/// Usage:
/// ```swift
/// Button(...) { ... }.recappiTooltip("Start recording (⏎)")
/// ```

extension View {
    func recappiTooltip(_ text: String) -> some View {
        modifier(RecappiTooltipModifier(text: text))
    }
}

private struct RecappiTooltipModifier: ViewModifier {
    let text: String
    @State private var anchor: NSView?
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .background(
                TooltipAnchorView { anchor = $0 }
                    .allowsHitTesting(false)
            )
            .onHover { hovering in
                if hovering, !text.isEmpty, let anchor {
                    RecappiTooltipController.shared.scheduleShow(text: text, anchor: anchor, token: token)
                } else {
                    RecappiTooltipController.shared.dismiss(token: token)
                }
            }
    }
}

private struct TooltipAnchorView: NSViewRepresentable {
    let onUpdate: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onUpdate(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Shared mutable text source the hosted SwiftUI view observes. Updating
/// `text` triggers a SwiftUI redraw inside the tooltip window with a
/// content-transition animation, so the morph between two anchored
/// tooltips cross-fades the label rather than tearing the whole pill.
@MainActor
private final class RecappiTooltipModel: ObservableObject {
    @Published var text: String = ""
    @Published var pillFrame: CGRect = .zero
    @Published var isVisible: Bool = false
}

@MainActor
final class RecappiTooltipController {
    static let shared = RecappiTooltipController()
    static let retargetFrameAnimationDuration: TimeInterval = 0
    static let carrierMorphDuration: TimeInterval = 0.18

    private var window: RecappiTooltipWindow?
    private var hostingView: NSHostingView<RecappiTooltipContent>?
    private let model = RecappiTooltipModel()
    private var currentToken: UUID?
    private var dwellWorkItem: DispatchWorkItem?
    private var dismissWorkItem: DispatchWorkItem?
    private var clickMonitor: Any?

    /// How long the cursor must rest on an unannounced button before the
    /// pill first appears. Matches macOS native tooltip dwell roughly.
    private let dwellDelay: TimeInterval = 0.6

    /// Grace window before `dismiss` actually tears the pill down. Lets
    /// the user move from one button to a neighbouring one without the
    /// pill flickering away — `scheduleShow` cancels the pending dismiss
    /// and the morph path kicks in.
    private let dismissGrace: TimeInterval = 0.18

    private let fadeDuration: TimeInterval = 0.15
    private let anchorGap: CGFloat = 6

    func scheduleShow(text: String, anchor: NSView, token: UUID) {
        // Cancel any pending dismiss — we're hovering again.
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        if window != nil {
            // Already on screen — retarget the same pill to the new anchor/text.
            currentToken = token
            retarget(to: text, anchor: anchor)
            return
        }

        // Fresh hover — wait for dwell delay before first appearance.
        dwellWorkItem?.cancel()
        currentToken = token
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.currentToken == token else { return }
                self.show(text: text, anchor: anchor)
            }
        }
        dwellWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwellDelay, execute: work)
    }

    func dismiss(token: UUID) {
        guard currentToken == token else { return }
        dwellWorkItem?.cancel()
        dwellWorkItem = nil
        currentToken = nil

        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.currentToken == nil else { return }
                self.fadeOut()
            }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissGrace, execute: work)
    }

    private func show(text: String, anchor: NSView) {
        guard let hostWindow = anchor.window else { return }
        let placement = placement(for: anchor, in: hostWindow, text: text)
        ensureCarrierWindow(frame: placement.carrierFrame, hostWindow: hostWindow)
        model.text = text
        model.pillFrame = placement.pillFrameInCarrier
        model.isVisible = false
        window?.orderFrontRegardless()
        installClickMonitorIfNeeded()

        withAnimation(.easeOut(duration: fadeDuration)) {
            model.isVisible = true
        }
    }

    private func retarget(to text: String, anchor: NSView) {
        guard let hostWindow = anchor.window else { return }

        // The model update drives the SwiftUI `.contentTransition(.opacity)`
        // inside the tooltip body. Keep the NSWindow frame itself fixed: a
        // material-backed panel stutters if AppKit animates both position and
        // size while the cursor is moving across dense toolbar buttons.
        let placement = placement(for: anchor, in: hostWindow, text: text)
        ensureCarrierWindow(frame: placement.carrierFrame, hostWindow: hostWindow)
        withAnimation(.smooth(duration: Self.carrierMorphDuration)) {
            model.text = text
            model.pillFrame = placement.pillFrameInCarrier
            model.isVisible = true
        }
    }

    private func fadeOut() {
        guard window != nil else { return }
        withAnimation(.easeOut(duration: fadeDuration)) {
            model.isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.currentToken == nil else { return }
                self.window?.orderOut(nil)
                self.window = nil
                self.hostingView = nil
                self.removeClickMonitor()
            }
        }
    }

    private func dismissImmediately() {
        dwellWorkItem?.cancel()
        dwellWorkItem = nil
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        currentToken = nil
        model.isVisible = false
        window?.orderOut(nil)
        window = nil
        hostingView = nil
        removeClickMonitor()
    }

    private func installClickMonitorIfNeeded() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor [weak self] in
                    self?.dismissImmediately()
                }
            }
            return event
        }
    }

    private func removeClickMonitor() {
        guard let clickMonitor else { return }
        NSEvent.removeMonitor(clickMonitor)
        self.clickMonitor = nil
    }

    private func ensureCarrierWindow(frame: NSRect, hostWindow: NSWindow) {
        if window == nil {
            let content = RecappiTooltipContent(model: model)
            let hosting = NSHostingView(rootView: content)
            hosting.frame = NSRect(origin: .zero, size: frame.size)
            hosting.autoresizingMask = [.width, .height]

            let win = RecappiTooltipWindow(contentRect: frame)
            win.appearance = hostWindow.contentView?.window?.appearance ?? NSApp.effectiveAppearance
            win.contentView = hosting
            win.setFrame(frame, display: false)

            self.window = win
            self.hostingView = hosting
            return
        }

        if let window, !window.frame.equalTo(frame) {
            window.setFrame(frame, display: false)
            hostingView?.frame = NSRect(origin: .zero, size: frame.size)
        }
        window?.appearance = hostWindow.contentView?.window?.appearance ?? NSApp.effectiveAppearance
    }

    /// Strictly clamp the tooltip rect to the visible screen. Below the
    /// anchor is the default (the floating panel sits at the top-right of
    /// the display, so "above" is regularly cropped by the menu bar).
    /// If neither below nor above fits cleanly, we pick the side with more
    /// room and clamp the corner so the pill is never partially off-screen.
    private func placement(for anchor: NSView, in hostWindow: NSWindow, text: String) -> TooltipPlacement {
        let anchorOnScreen = hostWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let tooltipSize = tooltipSize(for: text)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorOnScreen) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let inset: CGFloat = 8

        var x = anchorOnScreen.midX - tooltipSize.width / 2
        let minX = visible.minX + inset
        let maxX = visible.maxX - tooltipSize.width - inset
        if maxX >= minX {
            x = min(max(x, minX), maxX)
        } else {
            x = minX
        }

        let belowY = anchorOnScreen.minY - anchorGap - tooltipSize.height
        let aboveY = anchorOnScreen.maxY + anchorGap

        let belowFits = belowY >= visible.minY + inset
        let aboveFits = aboveY + tooltipSize.height <= visible.maxY - inset

        let y: CGFloat
        if belowFits {
            y = belowY
        } else if aboveFits {
            y = aboveY
        } else {
            // Neither side fits cleanly — choose whichever leaves more room
            // and clamp the corner so we are never partially off-screen.
            let belowRoom = belowY - visible.minY
            let aboveRoom = visible.maxY - (aboveY + tooltipSize.height)
            if belowRoom >= aboveRoom {
                y = max(visible.minY + inset, belowY)
            } else {
                y = min(visible.maxY - tooltipSize.height - inset, aboveY)
            }
        }

        let pillFrameOnScreen = NSRect(origin: CGPoint(x: x, y: y), size: tooltipSize)
        let pillFrameInCarrier = NSRect(
            x: pillFrameOnScreen.minX - visible.minX,
            y: visible.maxY - pillFrameOnScreen.maxY,
            width: pillFrameOnScreen.width,
            height: pillFrameOnScreen.height
        )
        return TooltipPlacement(carrierFrame: visible, pillFrameInCarrier: pillFrameInCarrier)
    }

    private func tooltipSize(for text: String) -> CGSize {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let rawSize = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(rawSize.width) + 22, height: ceil(font.ascender - font.descender) + 14)
    }
}

private struct TooltipPlacement {
    var carrierFrame: NSRect
    var pillFrameInCarrier: NSRect
}

private final class RecappiTooltipWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Stay above the app panels, but below native NSMenu popups. If this
        // uses `.popUpMenu`, opening a SwiftUI Menu can leave the tooltip
        // visually covering the dropdown until hover exit fires.
        level = .floating
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct RecappiTooltipContent: View {
    @ObservedObject var model: RecappiTooltipModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.isVisible {
                Text(model.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.labelPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.98)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    // `.opacity` content transition cross-fades the label
                    // when the string changes mid-flight, while the pill's
                    // frame moves inside a fixed carrier window.
                    .contentTransition(.opacity)
                    .frame(width: model.pillFrame.width, height: model.pillFrame.height)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Palette.borderHairline, lineWidth: 0.5)
                            }
                            .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 3)
                    }
                    .position(x: model.pillFrame.midX, y: model.pillFrame.midY)
                    .transition(.opacity)
                    .animation(.smooth(duration: RecappiTooltipController.carrierMorphDuration), value: model.pillFrame)
                    .animation(.smooth(duration: 0.14), value: model.text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
