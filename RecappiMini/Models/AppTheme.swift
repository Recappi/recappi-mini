import AppKit
import SwiftUI

/// User-selectable appearance for the whole app. Persisted via `AppConfig`
/// and applied at two layers: SwiftUI `.preferredColorScheme(_)` for the
/// scene/host roots, and `NSApp.appearance` so AppKit-managed `NSWindow` /
/// `NSPanel` chrome (traffic lights, sheets, dynamic colors) stays in sync.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }

    /// Value for SwiftUI `.preferredColorScheme(_)`. `nil` follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    /// Value for `NSApp.appearance`. `nil` follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}
