import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        hidesOnDeactivate = false

        // Don't steal focus from other apps
        becomesKeyOnlyIfNeeded = true
    }

    // Only become key when a text field needs input (settings API key)
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
    private(set) var contentView: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        layer?.addSublayer(chromeLayer)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setContent(_ view: NSView) {
        contentView?.removeFromSuperview()
        contentView = view
        addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        let m = Self.shadowMargin
        // Pin top + leading + trailing only — no bottom constraint so
        // hostingView grows to its SwiftUI intrinsic height. The window
        // then resizes to match (via the frame-change observer below).
        // If we pinned the bottom, NSHostingView would be clamped to the
        // shell's current height and SwiftUI content would be clipped
        // instead of growing.
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            view.topAnchor.constraint(equalTo: topAnchor, constant: m),
        ])
        // Clip the SwiftUI content to the rounded pill shape so nothing
        // spills past the chrome's corners.
        view.wantsLayer = true
        view.layer?.cornerRadius = Self.cornerRadius
        view.layer?.masksToBounds = true

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
        DispatchQueue.main.async { [weak self] in self?.syncWindowToContent() }
    }

    @objc private func contentFrameChanged(_ note: Notification) {
        syncWindowToContent()
    }

    private func syncWindowToContent() {
        guard let panel = window as? FloatingPanel, let inner = contentView else { return }
        let innerSize = inner.frame.size
        let desired = NSSize(
            width: innerSize.width + Self.shadowMargin * 2,
            height: innerSize.height + Self.shadowMargin * 2
        )
        guard panel.frame.size != desired else { return }
        FloatingPanelController.resizeToContent(panel, size: desired)
    }

    override var intrinsicContentSize: NSSize {
        guard let inner = contentView else { return .zero }
        let size = inner.frame.size
        let pad = Self.shadowMargin * 2
        return NSSize(width: size.width + pad, height: size.height + pad)
    }

    override func layout() {
        super.layout()
        let pillRect = bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
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
    }
}

@MainActor
struct FloatingPanelController {
    /// Positions the window so the *visible* pill sits 16pt from the
    /// top-right. The window extends `PillShellView.shadowMargin` past
    /// each pill edge (so the CALayer shadow has room); origin is
    /// offset accordingly.
    static func positionAtTopRight(_ panel: FloatingPanel, width: CGFloat, height: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let m = PillShellView.shadowMargin
        let windowWidth = width + m * 2
        let windowHeight = height + m * 2
        let x = screenFrame.maxX - width - 16 - m
        let y = screenFrame.maxY - height - 16 - m
        panel.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: true)
    }

    /// Resizes the panel to the given total window size while keeping
    /// the top edge anchored (panel grows/shrinks from the bottom).
    /// Called by `PillShellView` whenever its content's `fittingSize`
    /// changes, so the window tracks SwiftUI intrinsic size instead of
    /// a hard-coded per-state target.
    static func resizeToContent(_ panel: FloatingPanel, size: NSSize) {
        var frame = panel.frame
        let dy = frame.height - size.height
        frame.origin.y += dy
        frame.size = size
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }
}
