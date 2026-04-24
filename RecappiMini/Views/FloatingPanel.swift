import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    fileprivate var isFloatingTransitioning = false
    fileprivate var deferredContentSize: NSSize?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        // Shadow is owned by `PillShellView`'s CALayer via an explicit
        // `shadowPath` — much more reliable than trying to get NSPanel's
        // native shadow to trace the rounded SwiftUI alpha.
        hasShadow = false
        isMovableByWindowBackground = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        hidesOnDeactivate = false

        // Don't steal focus from other apps
        becomesKeyOnlyIfNeeded = true
    }

    // Only become key when a text field in settings needs input.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Don't activate the app when clicking the panel
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // Don't call makeKeyAndOrderFront
    }
}

/// Custom panel chrome: rounded charcoal pill with a proper drop shadow.
/// Uses `CALayer.shadowPath` so the shadow is deterministic and traces
/// the rounded shape — which NSPanel's native shadow couldn't reliably
/// do for SwiftUI-hosted transparent content.
final class PillShellView: NSView {
    /// Space around the chrome layer so the shadow isn't clipped by
    /// the window bounds.
    static let shadowMargin: CGFloat = 16
    static let cornerRadius: CGFloat = 14

    private let chromeLayer = CALayer()
    private let contentClipView = NSView()
    private(set) var contentView: NSView?
    private var pendingContentSync = false
    private var targetWindowSize: NSSize?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        layer?.addSublayer(chromeLayer)

        contentClipView.translatesAutoresizingMaskIntoConstraints = false
        contentClipView.wantsLayer = true
        contentClipView.layer?.cornerRadius = Self.cornerRadius
        contentClipView.layer?.masksToBounds = true
        addSubview(contentClipView)

        let m = Self.shadowMargin
        NSLayoutConstraint.activate([
            contentClipView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            contentClipView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            contentClipView.topAnchor.constraint(equalTo: topAnchor, constant: m),
            contentClipView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -m),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setContent(_ view: NSView) {
        contentView?.removeFromSuperview()
        contentView = view
        contentClipView.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        // Pin top + leading + trailing only. The hosting view may jump to
        // its final intrinsic height immediately, while the NSPanel animates
        // toward that height; contentClipView tracks the current pill bounds
        // and clips the interim overflow so content never leaks outside.
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentClipView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentClipView.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentClipView.topAnchor),
        ])

        // Resize the window whenever hostingView's frame (= SwiftUI
        // intrinsic height) changes.
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentFrameChanged(_:)),
            name: NSView.frameDidChangeNotification,
            object: view
        )
        // Also call once now so the initial layout matches intrinsic
        // size rather than the initial hard-coded panel contentRect.
        scheduleWindowSync()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func contentFrameChanged(_ note: Notification) {
        scheduleWindowSync()
    }

    private func scheduleWindowSync() {
        guard !pendingContentSync else { return }
        pendingContentSync = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingContentSync = false
            self.syncWindowToContent()
        }
    }

    private func syncWindowToContent() {
        guard let panel = window as? FloatingPanel, let inner = contentView else { return }
        let innerSize = measuredContentSize(for: inner)
        let desired = NSSize(
            width: innerSize.width + Self.shadowMargin * 2,
            height: innerSize.height + Self.shadowMargin * 2
        )
        if targetWindowSize?.isClose(to: desired) == true { return }
        guard !panel.frame.size.isClose(to: desired) else {
            targetWindowSize = desired
            return
        }
        targetWindowSize = desired
        if panel.isFloatingTransitioning {
            panel.deferredContentSize = desired
            return
        }
        FloatingPanelController.resizeToContent(panel, size: desired)
    }

    private func measuredContentSize(for view: NSView) -> NSSize {
        view.invalidateIntrinsicContentSize()
        view.layoutSubtreeIfNeeded()
        let fittingSize = view.fittingSize
        let frameSize = view.frame.size
        return NSSize(
            width: max(frameSize.width, fittingSize.width),
            height: fittingSize.height > 0 ? fittingSize.height : frameSize.height
        )
    }

    override var intrinsicContentSize: NSSize {
        guard let inner = contentView else { return .zero }
        let size = measuredContentSize(for: inner)
        let pad = Self.shadowMargin * 2
        return NSSize(width: size.width + pad, height: size.height + pad)
    }

    override func layout() {
        super.layout()
        let pillRect = bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chromeLayer.frame = pillRect
        chromeLayer.cornerRadius = Self.cornerRadius
        chromeLayer.masksToBounds = false
        chromeLayer.backgroundColor = NSColor(srgbRed: 0.179, green: 0.179, blue: 0.179, alpha: 1).cgColor
        chromeLayer.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        chromeLayer.borderWidth = 0.5
        chromeLayer.shadowColor = NSColor.black.cgColor
        chromeLayer.shadowOpacity = 0.45
        chromeLayer.shadowRadius = 8
        chromeLayer.shadowOffset = CGSize(width: 0, height: -4)
        chromeLayer.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: pillRect.size),
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
        contentClipView.layer?.cornerRadius = Self.cornerRadius
        CATransaction.commit()
    }
}

@MainActor
struct FloatingPanelController {
    /// Positions the window so the *visible* pill sits 16pt from the
    /// top-right. The window extends `PillShellView.shadowMargin` past
    /// each pill edge (so the CALayer shadow has room); origin is
    /// offset accordingly.
    static func positionAtTopRight(_ panel: FloatingPanel, width: CGFloat, height: CGFloat) {
        let m = PillShellView.shadowMargin
        let windowWidth = width + m * 2
        let windowHeight = height + m * 2
        let frame = visibleFrame(
            screen: panel.screen ?? NSScreen.main,
            panelSize: NSSize(width: windowWidth, height: windowHeight)
        )
        panel.setFrame(frame, display: true)
    }

    static func present(_ panel: FloatingPanel, completion: (() -> Void)? = nil) {
        let screen = panel.screen ?? NSScreen.main
        let visible = visibleFrame(screen: screen, panelSize: panel.frame.size)
        let hidden = hiddenFrame(screen: screen, panelSize: panel.frame.size)
        panel.isFloatingTransitioning = true
        panel.deferredContentSize = nil
        if panel.isVisible {
            panel.orderFrontRegardless()
        } else {
            panel.setFrame(hidden, display: false)
            panel.alphaValue = 0.92
            panel.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            ctx.completionHandler = {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
                if !panel.frame.origin.equalTo(visible.origin) || !panel.frame.size.isClose(to: visible.size) {
                    panel.setFrame(visible, display: false)
                }
                finishTransition(panel)
                completion?()
            }
            panel.animator().alphaValue = 1
            panel.animator().setFrame(visible, display: false)
        }
    }

    static func dismiss(_ panel: FloatingPanel, completion: (() -> Void)? = nil) {
        let hidden = hiddenFrame(screen: panel.screen ?? NSScreen.main, panelSize: panel.frame.size)
        panel.isFloatingTransitioning = true
        panel.deferredContentSize = nil

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.0, 0.7, 1.0)
            ctx.completionHandler = {
                if !panel.frame.origin.equalTo(hidden.origin) || !panel.frame.size.isClose(to: hidden.size) {
                    panel.setFrame(hidden, display: false)
                }
                panel.alphaValue = 1
                finishTransition(panel)
                completion?()
            }
            panel.animator().alphaValue = 0.92
            panel.animator().setFrame(hidden, display: false)
        }
    }

    /// Resizes the panel to the given total window size while keeping
    /// the top edge anchored (panel grows/shrinks from the bottom).
    /// Called by `PillShellView` whenever its content's `fittingSize`
    /// changes, so the window tracks SwiftUI intrinsic size instead of
    /// a hard-coded per-state target.
    static func resizeToContent(_ panel: FloatingPanel, size: NSSize) {
        if panel.isFloatingTransitioning {
            panel.deferredContentSize = size
            return
        }
        var frame = panel.frame
        let dy = frame.height - size.height
        frame.origin.y += dy
        frame.size = size
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private static func finishTransition(_ panel: FloatingPanel) {
        panel.isFloatingTransitioning = false
        guard let size = panel.deferredContentSize else { return }
        panel.deferredContentSize = nil
        resizeToContent(panel, size: size)
    }

    static func isPresented(_ panel: FloatingPanel) -> Bool {
        guard panel.isVisible else { return false }
        let visible = visibleFrame(screen: panel.screen ?? NSScreen.main, panelSize: panel.frame.size)
        let intersection = panel.frame.intersection(visible)
        guard !intersection.isNull else { return false }
        let visibleWidthRatio = intersection.width / max(panel.frame.width, 1)
        let visibleHeightRatio = intersection.height / max(panel.frame.height, 1)
        return visibleWidthRatio > 0.55 && visibleHeightRatio > 0.55
    }

    static func snapToVisible(_ panel: FloatingPanel) {
        let frame = visibleFrame(screen: panel.screen ?? NSScreen.main, panelSize: panel.frame.size)
        panel.setFrame(frame, display: true)
    }

    static func snapToHidden(_ panel: FloatingPanel) {
        let frame = hiddenFrame(screen: panel.screen ?? NSScreen.main, panelSize: panel.frame.size)
        panel.setFrame(frame, display: true)
    }

    private static func visibleFrame(screen: NSScreen?, panelSize: NSSize) -> NSRect {
        let screenFrame = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = screenFrame.maxX - panelSize.width + PillShellView.shadowMargin - 16
        let y = screenFrame.maxY - panelSize.height + PillShellView.shadowMargin - 16
        return NSRect(origin: CGPoint(x: x, y: y), size: panelSize)
    }

    private static func hiddenFrame(screen: NSScreen?, panelSize: NSSize) -> NSRect {
        let screenFrame = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var frame = visibleFrame(screen: screen, panelSize: panelSize)
        frame.origin.x = screenFrame.maxX + 12
        return frame
    }
}

private extension NSSize {
    func isClose(to other: NSSize, tolerance: CGFloat = 0.5) -> Bool {
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
