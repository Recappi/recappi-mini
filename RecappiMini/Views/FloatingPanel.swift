import AppKit
import Combine
import SwiftUI

struct FloatingPanelChromeView<Content: View>: View {
    let content: Content
    /// The chrome reads `colorScheme` directly — the host
    /// (`FloatingPanelHostingView`) flips its NSAppearance based on the
    /// backdrop luminance observer (task #185), and SwiftUI propagates
    /// the resulting `colorScheme` to this subtree. This keeps the chrome
    /// stateless and ensures every child label/icon that uses
    /// appearance-aware tokens (`Palette.label*`, `Color.primary`, etc.)
    /// flips in lockstep with the chrome background — the failure mode
    /// where peng-xiao reported invisible labels on dark backdrop.
    @Environment(\.colorScheme) private var colorScheme

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background {
                panelShape
                    .fill(liquidGlassLegibilityFill)
                    .glassEffect(in: panelShape)
                    .overlay {
                        panelShape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(isDarkMode ? 0.20 : 0.30),
                                        Color.white.opacity(isDarkMode ? 0.05 : 0.10),
                                        Color.clear,
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .blendMode(.screen)
                    }
                    .overlay {
                        panelShape
                            .strokeBorder(Color.white.opacity(isDarkMode ? 0.14 : 0.32), lineWidth: 0.6)
                    }
                    .allowsHitTesting(false)
            }
            .overlay {
                panelShape
                    .stroke(Palette.borderHairline, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .clipShape(panelShape)
            .compositingGroup()
            .animation(.easeInOut(duration: 0.25), value: isDarkMode)
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PillShellView.cornerRadius, style: .continuous)
    }

    private var liquidGlassLegibilityFill: Color {
        isDarkMode ? Color.black.opacity(0.28) : Color.white.opacity(0.16)
    }

    private var isDarkMode: Bool {
        colorScheme == .dark
    }
}

final class FloatingPanel: NSPanel {
    var isFloatingTransitioning = false
    fileprivate var deferredContentSize: NSSize?
    private nonisolated(unsafe) var localMouseMonitor: Any?
    private nonisolated(unsafe) var globalMouseMonitor: Any?
    private var dragStartMouseLocation: NSPoint?
    private var dragStartFrame: NSRect?
    private var didCustomDrag = false

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
        // SwiftUI owns the rounded chrome; PillShellView owns the shadow in
        // outer AppKit space so it cannot be clipped by the hosting view.
        // The transparent shadow margin is made click-through by the mouse
        // monitor below, so only the visible pill receives events.
        hasShadow = false
        isMovableByWindowBackground = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        hidesOnDeactivate = false

        // Don't steal focus from other apps
        becomesKeyOnlyIfNeeded = true
        installMousePassthroughMonitors()
    }

    // Only become key when a text field in settings needs input.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Don't activate the app when clicking the panel
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // Don't call makeKeyAndOrderFront
    }

    override func sendEvent(_ event: NSEvent) {
        if handleCustomDragEvent(event) {
            return
        }
        super.sendEvent(event)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        let screenFrame = (screen ?? self.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        guard !screenFrame.isEmpty else { return frameRect }
        return PillShellView.constrainWindowFrame(frameRect, visiblePillTo: screenFrame)
    }

    deinit {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
    }

    fileprivate func updateMousePassthrough() {
        guard isVisible else {
            ignoresMouseEvents = true
            return
        }

        // If a drag began inside the pill, keep receiving events until mouse-up
        // even if the cursor briefly leaves the rounded shape.
        if NSEvent.pressedMouseButtons != 0, ignoresMouseEvents == false {
            return
        }

        let localPoint = convertPoint(fromScreen: NSEvent.mouseLocation)
        let bounds = NSRect(origin: .zero, size: frame.size)
        ignoresMouseEvents = !PillShellView.visiblePillContains(localPoint, in: bounds)
    }

    private func handleCustomDragEvent(_ event: NSEvent) -> Bool {
        if Self.shouldRefreshMousePassthrough(for: event.type) {
            updateMousePassthrough()
        }

        switch event.type {
        case .leftMouseDown:
            beginCustomDragIfNeeded(with: event)
            return false
        case .leftMouseDragged:
            return continueCustomDrag()
        case .leftMouseUp:
            return finishCustomDrag()
        default:
            return false
        }
    }

    private func beginCustomDragIfNeeded(with event: NSEvent) {
        guard isVisible else { return }
        let localPoint = convertPoint(fromScreen: NSEvent.mouseLocation)
        let bounds = NSRect(origin: .zero, size: frame.size)
        guard PillShellView.visiblePillContains(localPoint, in: bounds) else { return }
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartFrame = frame
        didCustomDrag = false
    }

    private func continueCustomDrag() -> Bool {
        guard let dragStartMouseLocation,
              let dragStartFrame else { return false }
        let currentMouse = NSEvent.mouseLocation
        let distance = hypot(
            currentMouse.x - dragStartMouseLocation.x,
            currentMouse.y - dragStartMouseLocation.y
        )
        guard didCustomDrag || distance >= 3 else { return false }

        didCustomDrag = true
        let screenFrame = screenForPoint(currentMouse)?.visibleFrame
            ?? screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        let nextFrame = PillShellView.dragWindowFrame(
            startFrame: dragStartFrame,
            startMouse: dragStartMouseLocation,
            currentMouse: currentMouse,
            visiblePillTo: screenFrame
        )
        setFrame(nextFrame, display: false)
        return true
    }

    private func finishCustomDrag() -> Bool {
        let consumed = didCustomDrag
        dragStartMouseLocation = nil
        dragStartFrame = nil
        didCustomDrag = false
        updateMousePassthrough()
        return consumed
    }

    private func screenForPoint(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            NSMouseInRect(point, screen.frame, false)
        }
    }

    nonisolated static func shouldRefreshMousePassthrough(for eventType: NSEvent.EventType) -> Bool {
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return false
        default:
            return true
        }
    }

    private func installMousePassthroughMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
        ]

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.updateMousePassthrough()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateMousePassthrough()
            }
        }
    }
}

final class FloatingPanelHostingView<Root: View>: NSHostingView<Root> {
    override var mouseDownCanMoveWindow: Bool { false }

    /// Backdrop-adaptive chrome plumbing (task #185). The luminance
    /// observer publishes a single `prefersDarkChrome` flag; we react by
    /// overriding this hosting view's `appearance`, which in turn flips
    /// every appearance-aware `Palette` token and SwiftUI
    /// `@Environment(\.colorScheme)` inside the panel — so the chrome
    /// background, labels, and icons all adopt dark/light together
    /// instead of splitting into "dark shell, light text".
    ///
    /// When the user has chosen system dark mode globally we leave
    /// `appearance` unset so the host inherits — light backdrop should
    /// not yank the panel back to light against the user's preference.
    var luminanceObserver: BackdropLuminanceObserver? {
        didSet {
            luminanceSubscription?.cancel()
            luminanceSubscription = luminanceObserver?.$prefersDarkChrome
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.applyAdaptiveAppearance()
                }
            applyAdaptiveAppearance()
        }
    }

    private var luminanceSubscription: AnyCancellable?

    private func applyAdaptiveAppearance() {
        guard let observer = luminanceObserver else {
            appearance = nil
            return
        }
        let systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if systemIsDark {
            appearance = nil
            return
        }
        appearance = observer.prefersDarkChrome
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
    }
}

/// Sizing bridge between SwiftUI's intrinsic content size and the transparent
/// NSPanel window. Chrome and motion are SwiftUI-owned; this view keeps a real
/// AppKit safety margin around the hosted SwiftUI pill and draws the outer
/// panel shadow from the shell so it never touches the window edge.
final class PillShellView: NSView {
    /// Transparent window-space around the visible pill so the AppKit shadow
    /// is not clipped by the NSPanel bounds.
    nonisolated static let shadowMargin: CGFloat = 44
    nonisolated static let topShadowMargin: CGFloat = 20
    nonisolated static let cornerRadius: CGFloat = 14

    private(set) var contentView: NSView?
    private var pendingContentSync = false
    private var targetWindowSize: NSSize?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        updateShadowStyle()
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
            view.topAnchor.constraint(equalTo: topAnchor, constant: Self.topShadowMargin),
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateShadowStyle()
        updateShadowPath()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateShadowStyle()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard Self.visiblePillContains(point, in: bounds) else {
            return nil
        }
        return super.hitTest(point)
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
            height: innerSize.height + Self.topShadowMargin + Self.shadowMargin
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
        let pillRect = Self.visiblePillRect(in: bounds)
        guard pillRect.width > 0, pillRect.height > 0 else { return }
        layer?.shadowPath = CGPath(
            roundedRect: pillRect,
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
    }

    private func updateShadowStyle() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = isDark ? 0.38 : 0.20
        layer?.shadowRadius = isDark ? 18 : 16
        layer?.shadowOffset = CGSize(width: 0, height: -8)
    }

    nonisolated static func visiblePillRect(in bounds: NSRect) -> NSRect {
        NSRect(
            x: bounds.minX + shadowMargin,
            y: bounds.minY + shadowMargin,
            width: max(bounds.width - shadowMargin * 2, 0),
            height: max(bounds.height - topShadowMargin - shadowMargin, 0)
        )
    }

    nonisolated static func constrainWindowFrame(_ frame: NSRect, visiblePillTo screenFrame: NSRect) -> NSRect {
        var result = frame
        let pillSize = NSSize(
            width: max(frame.width - shadowMargin * 2, 1),
            height: max(frame.height - topShadowMargin - shadowMargin, 1)
        )

        if pillSize.width <= screenFrame.width {
            let pillMinX = result.minX + shadowMargin
            let pillMaxX = pillMinX + pillSize.width
            if pillMaxX > screenFrame.maxX {
                result.origin.x -= pillMaxX - screenFrame.maxX
            }
            if result.minX + shadowMargin < screenFrame.minX {
                result.origin.x += screenFrame.minX - (result.minX + shadowMargin)
            }
        } else {
            result.origin.x = screenFrame.minX - shadowMargin
        }

        if pillSize.height <= screenFrame.height {
            let pillMinY = result.minY + shadowMargin
            let pillMaxY = pillMinY + pillSize.height
            if pillMaxY > screenFrame.maxY {
                result.origin.y -= pillMaxY - screenFrame.maxY
            }
            if result.minY + shadowMargin < screenFrame.minY {
                result.origin.y += screenFrame.minY - (result.minY + shadowMargin)
            }
        } else {
            result.origin.y = screenFrame.minY - shadowMargin
        }

        return result
    }

    nonisolated static func dragWindowFrame(
        startFrame: NSRect,
        startMouse: NSPoint,
        currentMouse: NSPoint,
        visiblePillTo screenFrame: NSRect
    ) -> NSRect {
        let proposed = startFrame.offsetBy(
            dx: currentMouse.x - startMouse.x,
            dy: currentMouse.y - startMouse.y
        )
        return constrainWindowFrame(proposed, visiblePillTo: screenFrame)
    }

    nonisolated static func visiblePillContains(_ point: NSPoint, in bounds: NSRect) -> Bool {
        let rect = visiblePillRect(in: bounds)
        guard rect.width > 0, rect.height > 0 else { return false }
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        return path.contains(point)
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
        return NSSize(
            width: size.width + Self.shadowMargin * 2,
            height: size.height + Self.topShadowMargin + Self.shadowMargin
        )
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

        let animationKey = "recappi.panelContentTransition"
        let isInterruptingTransition = layer.animation(forKey: animationKey) != nil
        let fromTransform = isInterruptingTransition
            ? (layer.presentation()?.transform ?? layer.transform)
            : layer.transform
        let fromOpacity = isInterruptingTransition
            ? (layer.presentation()?.opacity ?? layer.opacity)
            : layer.opacity
        let toTransform = CATransform3DMakeTranslation(offsetX, 0, 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: animationKey)
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
        layer.add(group, forKey: animationKey)
        CATransaction.commit()
    }

    func resetTransition() {
        prepareTransition(offsetX: 0, opacity: 1)
    }

    var notificationTransitionOffset: CGFloat {
        max(bounds.width, 1) + Self.shadowMargin
    }
}

@MainActor
struct FloatingPanelController {
    private static var immediateResizeAnimationDeadline: CFTimeInterval = 0

    static func performNextContentResizesImmediately(duration: CFTimeInterval = 0.35) {
        immediateResizeAnimationDeadline = max(
            immediateResizeAnimationDeadline,
            CACurrentMediaTime() + duration
        )
    }

    /// Positions the visible pill 16pt from the top-right. The surrounding
    /// shadow margin is included in the window frame, but mouse events are
    /// only enabled while the pointer is inside the visible rounded pill.
    static func positionAtTopRight(_ panel: FloatingPanel, width: CGFloat, height: CGFloat) {
        let m = PillShellView.shadowMargin
        let windowWidth = width + m * 2
        let windowHeight = height + PillShellView.topShadowMargin + m
        let frame = visibleFrame(
            screen: panel.screen ?? NSScreen.main,
            panelSize: NSSize(width: windowWidth, height: windowHeight)
        )
        panel.ignoresMouseEvents = false
        panel.contentView?.setAccessibilityHidden(false)
        panel.setFrame(frame, display: true)
        panel.updateMousePassthrough()
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
            panel.contentView?.setAccessibilityHidden(false)
            shell?.resetTransition()
            panel.orderFrontRegardless()
            panel.updateMousePassthrough()
            finishTransition(panel)
            completion?()
        } else {
            // Moving an NSPanel's frame every animation tick is surprisingly
            // easy to hitch. Keep the window fixed and let Core Animation move
            // the layer contents instead.
            panel.setFrame(visible, display: false)
            panel.ignoresMouseEvents = false
            panel.contentView?.setAccessibilityHidden(false)
            panel.alphaValue = 1
            shell?.prepareTransition(offsetX: shell?.notificationTransitionOffset ?? 0, opacity: 1)
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            panel.updateMousePassthrough()

            guard let shell else {
                finishTransition(panel)
                completion?()
                return
            }

            shell.animateTransition(
                toOffsetX: 0,
                opacity: 1,
                duration: 0.22,
                timingFunction: CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
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
            panel.contentView?.setAccessibilityHidden(true)
            panel.orderOut(nil)
            finishTransition(panel)
            completion?()
            return
        }

        shell.animateTransition(
            toOffsetX: shell.notificationTransitionOffset,
            opacity: 1,
            duration: 0.18,
            timingFunction: CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
        ) {
            panel.setFrame(hidden, display: false)
            panel.ignoresMouseEvents = true
            panel.contentView?.setAccessibilityHidden(true)
            panel.orderOut(nil)
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
        let frame = contentResizeFrame(from: panel.frame, to: size)
        guard !framesNearlyMatch(panel.frame, frame) else {
            panel.updateMousePassthrough()
            return
        }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !panel.isVisible || shouldResizeImmediately {
            panel.setFrame(frame, display: false)
            panel.updateMousePassthrough()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = DT.Motion.panelResize
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: false)
        } completionHandler: {
            Task { @MainActor in
                panel.updateMousePassthrough()
            }
        }
    }

    nonisolated static func contentResizeFrame(from frame: NSRect, to size: NSSize) -> NSRect {
        var resized = frame
        let dy = frame.height - size.height
        resized.origin.y += dy
        resized.size = size
        return resized
    }

    private static var shouldResizeImmediately: Bool {
        CACurrentMediaTime() <= immediateResizeAnimationDeadline
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
        panel.ignoresMouseEvents = false
        panel.contentView?.setAccessibilityHidden(false)
        (panel.contentView as? PillShellView)?.resetTransition()
        guard !framesNearlyMatch(panel.frame, frame) else {
            panel.updateMousePassthrough()
            return
        }
        panel.setFrame(frame, display: true)
        panel.updateMousePassthrough()
    }

    static func snapToHidden(_ panel: FloatingPanel) {
        let frame = hiddenFrame(screen: panel.screen ?? NSScreen.main, panelSize: panel.frame.size)
        panel.ignoresMouseEvents = true
        panel.contentView?.setAccessibilityHidden(true)
        guard !framesNearlyMatch(panel.frame, frame) else {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(frame, display: true)
        panel.orderOut(nil)
    }

    private static func framesNearlyMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5
            && abs(lhs.origin.y - rhs.origin.y) < 0.5
            && abs(lhs.size.width - rhs.size.width) < 0.5
            && abs(lhs.size.height - rhs.size.height) < 0.5
    }

    private static func visibleFrame(screen: NSScreen?, panelSize: NSSize) -> NSRect {
        let screenFrame = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = screenFrame.maxX - panelSize.width + PillShellView.shadowMargin - 16
        let y = screenFrame.maxY - panelSize.height + PillShellView.topShadowMargin - 16
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
