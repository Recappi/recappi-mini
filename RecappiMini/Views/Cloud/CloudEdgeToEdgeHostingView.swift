import AppKit
import SwiftUI

/// `NSWindow.StyleMask.fullSizeContentView` still lets AppKit expose a
/// non-zero safe area through `NSHostingView` when the native title bar is
/// hidden. The Cloud window owns all of its chrome in SwiftUI, including the
/// bottom mini-player, so its hosted content should draw edge-to-edge.
final class CloudEdgeToEdgeHostingView<Root: View>: NSHostingView<Root> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
}
