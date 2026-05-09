import AppKit

enum WindowFactory {
    struct WindowSpec {
        let contentRect: NSRect
        let styleMask: NSWindow.StyleMask
        let title: String
        var titlebarAppearsTransparent = true
        var titleVisibility: NSWindow.TitleVisibility = .visible
        var hiddenStandardButtons: [NSWindow.ButtonType] = []
        var isReleasedWhenClosed = false
        var isMovableByWindowBackground = false
        var contentMinSize: NSSize?
        var contentMaxSize: NSSize?
    }

    struct PanelSpec {
        let contentRect: NSRect
        let styleMask: NSWindow.StyleMask
        let title: String
        var isFloatingPanel = true
        var level: NSWindow.Level = .floating
        var isOpaque = false
        var backgroundColor: NSColor = .clear
        var hasShadow = false
        var hidesOnDeactivate = false
        var isMovableByWindowBackground = true
        var isReleasedWhenClosed = false
        var collectionBehavior: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Title-bar chrome controls — used to keep a chromeless
        // floating-panel look when `.titled` is in the styleMask
        // (needed for `.resizable` to work on a panel).
        var titleVisibility: NSWindow.TitleVisibility = .visible
        var titlebarAppearsTransparent = false
        var hiddenStandardButtons: [NSWindow.ButtonType] = []
    }

    @MainActor
    static func createWindow(
        contentView: NSView,
        spec: WindowSpec,
        delegate: NSWindowDelegate
    ) -> NSWindow {
        contentView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: spec.contentRect,
            styleMask: spec.styleMask,
            backing: .buffered,
            defer: false
        )
        applySharedWindowConfig(window, spec: spec, contentView: contentView, delegate: delegate)
        return window
    }

    @MainActor
    static func createPanel(
        contentView: NSView,
        spec: PanelSpec,
        delegate: NSWindowDelegate
    ) -> NSPanel {
        contentView.autoresizingMask = [.width, .height]

        let panel = NSPanel(
            contentRect: spec.contentRect,
            styleMask: spec.styleMask,
            backing: .buffered,
            defer: false
        )
        panel.title = spec.title
        panel.isFloatingPanel = spec.isFloatingPanel
        panel.level = spec.level
        panel.isOpaque = spec.isOpaque
        panel.backgroundColor = spec.backgroundColor
        panel.hasShadow = spec.hasShadow
        panel.hidesOnDeactivate = spec.hidesOnDeactivate
        panel.isMovableByWindowBackground = spec.isMovableByWindowBackground
        panel.isReleasedWhenClosed = spec.isReleasedWhenClosed
        panel.collectionBehavior = spec.collectionBehavior
        panel.titleVisibility = spec.titleVisibility
        panel.titlebarAppearsTransparent = spec.titlebarAppearsTransparent
        for button in spec.hiddenStandardButtons {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.contentView = contentView
        panel.delegate = delegate
        return panel
    }

    @MainActor
    private static func applySharedWindowConfig(
        _ window: NSWindow,
        spec: WindowSpec,
        contentView: NSView,
        delegate: NSWindowDelegate
    ) {
        window.title = spec.title
        window.titlebarAppearsTransparent = spec.titlebarAppearsTransparent
        window.titleVisibility = spec.titleVisibility
        for button in spec.hiddenStandardButtons {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isReleasedWhenClosed = spec.isReleasedWhenClosed
        window.isMovableByWindowBackground = spec.isMovableByWindowBackground
        if let contentMinSize = spec.contentMinSize {
            window.contentMinSize = contentMinSize
        }
        if let contentMaxSize = spec.contentMaxSize {
            window.contentMaxSize = contentMaxSize
        }
        window.contentView = contentView
        window.delegate = delegate
        window.center()
    }
}
