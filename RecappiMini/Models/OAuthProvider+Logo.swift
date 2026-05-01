import AppKit

extension OAuthProvider {
    /// Shared brand mark used across every OAuth sign-in surface
    /// (`CloudCenterPanel` empty state, `OnboardingView` SignIn step,
    /// and `SettingsView` Account row). The asset names mirror the
    /// PNGs shipped under `RecappiMini/Resources/`.
    ///
    /// `GitHubMark.png` is a black silhouette with an alpha channel,
    /// which AppKit's automatic template detection happily classifies
    /// as a template image. SwiftUI then tints templates to the
    /// foreground colour — on a dark provider button (default white
    /// label on near-black fill) that renders the GitHub mark as a
    /// solid white square. Force `isTemplate = false` so the original
    /// silhouette is preserved everywhere we draw it.
    var logoImage: NSImage {
        let resourceName: String
        switch self {
        case .google: resourceName = "GoogleG"
        case .github: resourceName = "GitHubMark"
        }
        guard let image = NSImage(named: resourceName) else { return NSImage() }
        let copy = image.copy() as? NSImage ?? image
        copy.isTemplate = false
        return copy
    }
}
