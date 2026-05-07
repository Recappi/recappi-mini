import Foundation

/// Collapses child bundle IDs onto their parent. Chrome-style multi-process
/// apps emit audio from `.helper(.Renderer)` / `.Agent` subprocesses; the
/// user recognises the app by its parent bundle, so both the selector and
/// the activity monitor need the same canonicalisation.
enum BundleCollapser {
    private static let markers: [String] = [
        ".helper", ".Helper",
        ".renderer", ".Renderer",
        ".agent", ".Agent",
        ".plugin_host",
    ]

    private static let canonicalBundleIDsByLowercase: [String: String] = [
        "com.apple.safari": "com.apple.Safari",
        "com.google.chrome": "com.google.Chrome",
        "com.google.chrome.beta": "com.google.Chrome.beta",
        "com.google.chrome.canary": "com.google.Chrome.canary",
        "com.brave.browser": "com.brave.Browser",
        "company.thebrowser.browser": "company.thebrowser.Browser",
        "company.thebrowser.arc": "company.thebrowser.Browser",
        "com.microsoft.edgemac": "com.microsoft.edgemac",
        "com.vivaldi.vivaldi": "com.vivaldi.Vivaldi",
        "com.operasoftware.opera": "com.operasoftware.Opera",
    ]

    static func parent(of bundleID: String) -> String {
        let stripped: String
        if let range = markers
            .compactMap({ bundleID.range(of: $0, options: [.caseInsensitive]) })
            .min(by: { $0.lowerBound < $1.lowerBound }) {
            stripped = String(bundleID[..<range.lowerBound])
        } else {
            stripped = bundleID
        }

        return canonicalBundleID(stripped)
    }

    static func matches(_ bundleID: String, selected selectedBundleID: String) -> Bool {
        let candidateParent = parent(of: bundleID)
        let selectedParent = parent(of: selectedBundleID)
        if candidateParent == selectedParent { return true }

        let candidate = bundleID.lowercased()
        let selected = selectedParent.lowercased()
        return candidate == selected || candidate.hasPrefix("\(selected).")
    }

    private static func canonicalBundleID(_ bundleID: String) -> String {
        canonicalBundleIDsByLowercase[bundleID.lowercased()] ?? bundleID
    }

    static func canonicalBrowserBundleID(for appName: String) -> String? {
        let normalized = appName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "arc", "arc browser":
            return "company.thebrowser.Browser"
        case "google chrome", "chrome":
            return "com.google.Chrome"
        case "safari":
            return "com.apple.Safari"
        case "brave browser", "brave":
            return "com.brave.Browser"
        case "microsoft edge", "edge":
            return "com.microsoft.edgemac"
        case "vivaldi":
            return "com.vivaldi.Vivaldi"
        case "opera":
            return "com.operasoftware.Opera"
        default:
            return nil
        }
    }

    static func browserDisplayName(for bundleID: String, fallback: String) -> String {
        switch parent(of: bundleID) {
        case "company.thebrowser.Browser":
            return "Arc"
        case "com.google.Chrome":
            return "Google Chrome"
        case "com.apple.Safari":
            return "Safari"
        default:
            if let canonical = canonicalBrowserBundleID(for: fallback) {
                switch canonical {
                case "company.thebrowser.Browser": return "Arc"
                case "com.google.Chrome": return "Google Chrome"
                case "com.apple.Safari": return "Safari"
                default: break
                }
            }
            return fallback
        }
    }
}
