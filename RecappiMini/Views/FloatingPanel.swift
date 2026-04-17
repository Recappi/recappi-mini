import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    // Persisted as "x,top" — top = origin.y + height (top-anchored so resize doesn't drift it).
    private static let positionKey = "RecappiMini.panelAnchor"

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

        // Panel is app-lifetime, so no teardown needed; observer closure just no-ops after weak self goes away.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persistAnchor()
            }
        }
    }

    // Only become key when a text field needs input (settings API key)
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Don't activate the app when clicking the panel
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // Don't call makeKeyAndOrderFront
    }

    private func persistAnchor() {
        let top = frame.origin.y + frame.size.height
        UserDefaults.standard.set("\(frame.origin.x),\(top)", forKey: Self.positionKey)
    }

    /// Returns the persisted (x, top) anchor if it still lands on a visible screen.
    static func savedAnchor() -> (x: CGFloat, top: CGFloat)? {
        guard let str = UserDefaults.standard.string(forKey: positionKey) else { return nil }
        let parts = str.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        let x = CGFloat(parts[0])
        let top = CGFloat(parts[1])
        // Require a small test rectangle near the anchor to stay inside a visible screen,
        // so a disconnected display or resolution change falls back to top-right.
        let probe = NSRect(x: x, y: top - 20, width: 40, height: 20)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(probe) }
        return onScreen ? (x, top) : nil
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

    /// Restore from UserDefaults if the saved anchor is on a visible screen; otherwise top-right.
    static func restoreOrTopRight(_ panel: FloatingPanel, width: CGFloat, height: CGFloat) {
        if let anchor = FloatingPanel.savedAnchor() {
            let frame = NSRect(x: anchor.x, y: anchor.top - height, width: width, height: height)
            panel.setFrame(frame, display: true)
        } else {
            positionAtTopRight(panel, width: width, height: height)
        }
    }

    static func resize(_ panel: FloatingPanel, height: CGFloat) {
        var frame = panel.frame
        let dy = frame.height - height
        frame.origin.y += dy
        frame.size.height = height
        panel.animator().setFrame(frame, display: true)
    }
}
