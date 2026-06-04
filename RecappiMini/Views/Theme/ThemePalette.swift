import AppKit
import SwiftUI

/// Semantic, appearance-aware color tokens. Each token is backed by a
/// dynamic `NSColor` — the system re-resolves it whenever the rendering
/// view's `effectiveAppearance` changes (which happens automatically when
/// `NSApp.appearance` flips, see `ThemeManager`).
///
/// Add new design colors here rather than inlining `Color(red:…)` /
/// `Color.white.opacity(_)` at call sites. The dark variants preserve the
/// charcoal palette the app shipped with; light variants are tuned to read
/// well on a near-white window without losing the existing layering.
enum Palette {
    // MARK: - Surfaces

    /// Outermost window background (Settings, Cloud, About).
    static let surfaceWindow = dynamic(light: 0xF7F7F8, dark: 0x1C1C1C)
    /// Floating recording pill / settings card chrome.
    static let surfacePanel = dynamic(light: 0xFFFFFF, dark: 0x2D2D2D)
    /// Inset chip controls on the recording pill (stop / share / trash).
    static let surfaceChip = dynamic(light: 0xEFEFF1, dark: 0x424242)
    /// Elevated card surfaces (sheets, popovers).
    static let surfaceElevated = dynamic(light: 0xFFFFFF, dark: 0x333333)
    /// Live-captions overlay (slightly lifted from `surfacePanel` in dark).
    static let surfaceLiveCaption = dynamic(light: 0xF2F2F4, dark: 0x474747)
    /// Reading-pane card background (transcript card, summary insight cards).
    /// Light: clean white inset against the slightly off-white window;
    /// dark: charcoal step lighter than `surfaceWindow` so cards lift cleanly
    /// without the old `ultraThinMaterial + black 0.24` muddied look.
    static let surfaceCard = dynamic(light: 0xFFFFFF, dark: 0x232323)
    /// Subtle inset for rows inside `surfaceCard` (e.g. transcript segments).
    /// Designed to be barely-there in both modes.
    static let surfaceCardSubtle = dynamicAlpha(light: (0x000000, 0.025), dark: (0xFFFFFF, 0.012))
    /// Selected/active row tint inside a card (slightly more visible).
    static let surfaceCardSubtleActive = dynamicAlpha(light: (0x000000, 0.045), dark: (0xFFFFFF, 0.035))

    // MARK: - Borders

    static let borderHairline = dynamicAlpha(light: (0x000000, 0.10), dark: (0xFFFFFF, 0.06))
    static let borderSubtle   = dynamicAlpha(light: (0x000000, 0.14), dark: (0xFFFFFF, 0.10))
    static let borderStrong   = dynamicAlpha(light: (0x000000, 0.22), dark: (0xFFFFFF, 0.18))

    // MARK: - Control fills (hover / press)

    static let controlFillHover = dynamicAlpha(light: (0x000000, 0.05), dark: (0xFFFFFF, 0.07))
    static let controlFillPress = dynamicAlpha(light: (0x000000, 0.08), dark: (0xFFFFFF, 0.12))

    // MARK: - Labels (formerly `Color.white.opacity(0.92/0.62/0.38/0.16)`)

    static let labelPrimary    = dynamicAlpha(light: (0x000000, 0.92), dark: (0xFFFFFF, 0.92))
    static let labelSecondary  = dynamicAlpha(light: (0x000000, 0.60), dark: (0xFFFFFF, 0.62))
    static let labelTertiary   = dynamicAlpha(light: (0x000000, 0.40), dark: (0xFFFFFF, 0.38))
    static let labelQuaternary = dynamicAlpha(light: (0x000000, 0.20), dark: (0xFFFFFF, 0.16))

    // MARK: - Glass-shell text (recording floating panel)
    //
    // The recording pill / status toast float on a translucent glass shell over
    // arbitrary desktop content. The `BackdropLuminanceObserver` (task #185)
    // flips this shell's appearance by average backdrop luminance, so text here
    // still tracks light/dark — but the regular `label*` weak tiers wash out
    // when a busy/colorful wallpaper bleeds through the glass (peng-xiao 6/4).
    // These carry the same appearance behavior with higher minimum contrast,
    // especially the tertiary tier. Use them for non-semantic copy on the
    // recording shell; keep `label*` for opaque app pages (Cloud/Settings).
    static let recordingGlassTextPrimary   = dynamicAlpha(light: (0x000000, 0.95), dark: (0xFFFFFF, 0.95))
    static let recordingGlassTextSecondary = dynamicAlpha(light: (0x000000, 0.78), dark: (0xFFFFFF, 0.80))
    static let recordingGlassTextTertiary  = dynamicAlpha(light: (0x000000, 0.62), dark: (0xFFFFFF, 0.64))

    // MARK: - Accent

    /// Recappi green should not be the same physical color in both
    /// appearances: light glass needs a deeper green to avoid blooming, while
    /// dark glass needs a brighter green to keep the accent alive.
    static let appAccent = dynamic(light: 0x047857, dark: 0x34D399)
    static let appAccentDeep = dynamic(light: 0x065F46, dark: 0x10B981)
    static let appAccentSoft = dynamic(light: 0x059669, dark: 0x6EE7B7)
    static let waveformUnlit = dynamicAlpha(light: (0x111827, 0.22), dark: (0xFFFFFF, 0.20))

    // MARK: - Shadows

    static let shadowPanel = dynamicAlpha(light: (0x000000, 0.18), dark: (0x000000, 0.45))

    // MARK: - Helpers

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(rgbHex: appearance.isDark ? dark : light)
        })
    }

    private static func dynamicAlpha(
        light: (UInt32, Double),
        dark: (UInt32, Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let pair = appearance.isDark ? dark : light
            return NSColor(rgbHex: pair.0).withAlphaComponent(CGFloat(pair.1))
        })
    }
}

private extension NSAppearance {
    /// `bestMatch(from:)` resolves the appearance through any inherited
    /// vibrancy variants — so this works correctly inside sheets, sidebars,
    /// and accent-tinted controls.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

private extension NSColor {
    convenience init(rgbHex: UInt32) {
        self.init(
            srgbRed: CGFloat((rgbHex >> 16) & 0xFF) / 255,
            green: CGFloat((rgbHex >> 8) & 0xFF) / 255,
            blue: CGFloat(rgbHex & 0xFF) / 255,
            alpha: 1
        )
    }
}
