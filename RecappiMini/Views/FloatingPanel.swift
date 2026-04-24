import AppKit
import SwiftUI

struct FloatingPanelChromeView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background {
                RoundedRectangle(cornerRadius: PillShellView.cornerRadius, style: .continuous)
                    .fill(Color(red: 0.179, green: 0.179, blue: 0.179))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: PillShellView.cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.06), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: PillShellView.cornerRadius, style: .continuous))
    }
}

final class FloatingPanel: NSPanel {
    var isFloatingTransitioning = false
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
        // SwiftUI owns the rounded chrome and drop shadow. The AppKit shell
        // only provides a transparent safety margin so that shadow can render
        // outside the visible pill without being clipped by the window bounds.
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

/// Sizing bridge between SwiftUI's intrinsic content size and the transparent
/// NSPanel window. Chrome and motion are SwiftUI-owned; this view keeps a real
/// AppKit safety margin around the hosted SwiftUI pill so shadows never touch
/// the window edge.
final class PillShellView: NSView {
    /// Transparent window-space around the visible pill so SwiftUI shadows
    /// are not clipped by the NSPanel bounds.
    static let shadowMargin: CGFloat = 24
    static let cornerRadius: CGFloat = 14
    static let transitionOffset: CGFloat = 28

    private(set) var contentView: NSView?
    private var pendingContentSync = false
    private var targetWindowSize: NSSize?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -4)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setContent(_ view: NSView) {
        contentView?.removeFromSuperview()
        contentView = view
        addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        let m = Self.shadowMargin
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            view.topAnchor.constraint(equalTo: topAnchor, constant: m),
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

    override func layout() {
        super.layout()
        updateShadowPath()
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

    private func updateShadowPath() {
        let m = Self.shadowMargin
        let pillRect = bounds.insetBy(dx: m, dy: m)
        guard pillRect.width > 0, pillRect.height > 0 else { return }
        layer?.shadowPath = CGPath(
            roundedRect: pillRect,
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
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

    func prepareTransition(offsetX: CGFloat, opacity: Float) {
        guard let layer else { return }
        layer.removeAnimation(forKey: "recappi.panelContentTransition")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(offsetX, 0, 0)
        layer.opacity = opacity
        CATransaction.commit()
    }

    func animateTransition(
        toOffsetX offsetX: CGFloat,
        opacity: Float,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction,
        completion: @escaping () -> Void
    ) {
        guard let layer else {
            completion()
            return
        }

        let fromTransform = layer.presentation()?.transform ?? layer.transform
        let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
        let toTransform = CATransform3DMakeTranslation(offsetX, 0, 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "recappi.panelContentTransition")
        layer.transform = toTransform
        layer.opacity = opacity
        CATransaction.commit()

        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: fromTransform)
        transform.toValue = NSValue(caTransform3D: toTransform)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = opacity

        let group = CAAnimationGroup()
        group.animations = [transform, fade]
        group.duration = duration
        group.timingFunction = timingFunction
        group.fillMode = .removed
        group.isRemovedOnCompletion = true

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.add(group, forKey: "recappi.panelContentTransition")
        CATransaction.commit()
    }

    func resetTransition() {
        prepareTransition(offsetX: 0, opacity: 1)
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
        panel.isFloatingTransitioning = true
        panel.deferredContentSize = nil
        let shell = panel.contentView as? PillShellView
        if isPresented(panel) {
            panel.setFrame(visible, display: false)
            panel.ignoresMouseEvents = false
            shell?.resetTransition()
            panel.orderFrontRegardless()
            finishTransition(panel)
            completion?()
        } else {
            // Moving an NSPanel's frame every animation tick is surprisingly
            // easy to hitch. Keep the window fixed and let Core Animation move
            // the layer contents instead.
            panel.setFrame(visible, display: false)
            panel.ignoresMouseEvents = false
            panel.alphaValue = 1
            shell?.prepareTransition(offsetX: PillShellView.transitionOffset, opacity: 0)
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }

            guard let shell else {
                finishTransition(panel)
                completion?()
                return
            }

            shell.animateTransition(
                toOffsetX: 0,
                opacity: 1,
                duration: 0.14,
                timingFunction: CAMediaTimingFunction(controlPoints: 0.23, 1.0, 0.32, 1.0)
            ) {
                panel.orderFrontRegardless()
                finishTransition(panel)
                completion?()
            }
        }
    }

    static func dismiss(_ panel: FloatingPanel, completion: (() -> Void)? = nil) {
        let hidden = hiddenFrame(screen: panel.screen ?? NSScreen.main, panelSize: panel.frame.size)
        panel.isFloatingTransitioning = true
        panel.deferredContentSize = nil
        let shell = panel.contentView as? PillShellView

        guard let shell else {
            panel.setFrame(hidden, display: false)
            panel.ignoresMouseEvents = true
            finishTransition(panel)
            completion?()
            return
        }

        shell.animateTransition(
            toOffsetX: PillShellView.transitionOffset,
            opacity: 0,
            duration: 0.12,
            timingFunction: CAMediaTimingFunction(controlPoints: 0.23, 1.0, 0.32, 1.0)
        ) {
            panel.setFrame(hidden, display: false)
            panel.ignoresMouseEvents = true
            shell.resetTransition()
            finishTransition(panel)
            completion?()
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
        panel.setFrame(frame, display: false)
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
