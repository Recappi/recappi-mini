import AppKit

enum MenuBarIconFactory {
    static func idleIcon() -> NSImage {
        let image = Bundle.main.url(forResource: "LogoTemplate", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(named: "LogoTemplate")
            ?? NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Recappi Mini")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}

final class StatusRecordingDotView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
