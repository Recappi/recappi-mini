import Foundation
import RecappiCaptureCore

/// Collapses child bundle IDs onto their parent. Chrome-style multi-process
/// apps emit audio from `.helper(.Renderer)` / `.Agent` subprocesses; the
/// user recognises the app by its parent bundle, so both the selector and
/// the activity monitor need the same canonicalisation.
enum BundleCollapser {
    static func parent(of bundleID: String) -> String {
        CaptureBundleCollapser.parent(of: bundleID)
    }

    static func matches(_ bundleID: String, selected selectedBundleID: String) -> Bool {
        CaptureBundleCollapser.matches(bundleID, selected: selectedBundleID)
    }

    static func canonicalBrowserBundleID(for appName: String) -> String? {
        CaptureBundleCollapser.canonicalBrowserBundleID(for: appName)
    }

    static func browserDisplayName(for bundleID: String, fallback: String) -> String {
        CaptureBundleCollapser.browserDisplayName(for: bundleID, fallback: fallback)
    }
}
