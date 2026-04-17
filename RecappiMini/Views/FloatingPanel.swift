import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
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

@MainActor
struct FloatingPanelController {
    static func positionAtTopRight(_ panel: FloatingPanel, width: CGFloat, height: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.maxX - width - 16
        let y = screenFrame.maxY - height - 16
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    static func resize(_ panel: FloatingPanel, height: CGFloat) {
        var frame = panel.frame
        let dy = frame.height - height
        frame.origin.y += dy
        frame.size.height = height
        // Match the SwiftUI easeOut(0.2) content transition. easeOut avoids
        // the mid-point acceleration that reads as a "bounce" when combined
        // with NSHostingView's intrinsicContentSize updates.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }
}
