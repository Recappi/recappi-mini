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
///    tooltip is already showing, the same pill *morphs* — its frame
///    animates from old anchor to new anchor and the text inside cross-
///    fades — instead of fading out + fading in two separate tooltips.
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
}

@MainActor
final class RecappiTooltipController {
    static let shared = RecappiTooltipController()

    private var window: RecappiTooltipWindow?
    private var hostingView: NSHostingView<RecappiTooltipContent>?
    private let model = RecappiTooltipModel()
    private var currentToken: UUID?
    private var dwellWorkItem: DispatchWorkItem?
    private var dismissWorkItem: DispatchWorkItem?

    /// How long the cursor must rest on an unannounced button before the
    /// pill first appears. Matches macOS native tooltip dwell roughly.
    private let dwellDelay: TimeInterval = 0.6

    /// Grace window before `dismiss` actually tears the pill down. Lets
    /// the user move from one button to a neighbouring one without the
    /// pill flickering away — `scheduleShow` cancels the pending dismiss
    /// and the morph path kicks in.
    private let dismissGrace: TimeInterval = 0.18

    private let fadeDuration: TimeInterval = 0.15
    private let morphDuration: TimeInterval = 0.22
    private let anchorGap: CGFloat = 6

    func scheduleShow(text: String, anchor: NSView, token: UUID) {
        // Cancel any pending dismiss — we're hovering again.
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        if window != nil {
            // Already on screen — morph instantly to the new anchor/text.
            currentToken = token
            morph(to: text, anchor: anchor)
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
        model.text = text
        let content = RecappiTooltipContent(model: model)
        let hosting = NSHostingView(rootView: content)
        hosting.layoutSubtreeIfNeeded()

        let win = RecappiTooltipWindow()
        win.appearance = hostWindow.contentView?.window?.appearance ?? NSApp.effectiveAppearance
        win.contentView = hosting

        let size = hosting.fittingSize
        let anchorOnScreen = hostWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let origin = placement(anchorOnScreen: anchorOnScreen, tooltipSize: size)
        win.setFrame(NSRect(origin: origin, size: size), display: true)
        win.alphaValue = 0
        win.orderFrontRegardless()

        self.window = win
        self.hostingView = hosting

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeDuration
            win.animator().alphaValue = 1
        }
    }

    private func morph(to text: String, anchor: NSView) {
        guard let win = window, let hosting = hostingView, let hostWindow = anchor.window else { return }

        // The model update drives the SwiftUI `.contentTransition(.opacity)`
        // inside the tooltip body, so the *text* cross-fades while the
        // *window frame* animates in lockstep below.
        model.text = text
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let anchorOnScreen = hostWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let origin = placement(anchorOnScreen: anchorOnScreen, tooltipSize: size)
        let target = NSRect(origin: origin, size: size)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = morphDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1)
            ctx.allowsImplicitAnimation = true
            win.animator().setFrame(target, display: true)
        }
    }

    private func fadeOut() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.currentToken == nil else { return }
                self.window?.orderOut(nil)
                self.window = nil
                self.hostingView = nil
            }
        })
    }

    /// Strictly clamp the tooltip rect to the visible screen. Below the
    /// anchor is the default (the floating panel sits at the top-right of
    /// the display, so "above" is regularly cropped by the menu bar).
    /// If neither below nor above fits cleanly, we pick the side with more
    /// room and clamp the corner so the pill is never partially off-screen.
    private func placement(anchorOnScreen: CGRect, tooltipSize: CGSize) -> CGPoint {
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
        return CGPoint(x: x, y: y)
    }
}

private final class RecappiTooltipWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
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
        Text(model.text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.labelPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .fixedSize(horizontal: true, vertical: false)
            // `.opacity` content transition cross-fades the label when the
            // string changes mid-flight, giving the morph between adjacent
            // buttons a continuous feel rather than two separate pills.
            .contentTransition(.opacity)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Palette.borderHairline, lineWidth: 0.5)
                    }
                    .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 3)
            }
            .padding(2)
            .animation(.smooth(duration: 0.18), value: model.text)
    }
}
