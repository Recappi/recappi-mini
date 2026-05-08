import SwiftUI

/// Wraps a SwiftUI view tree before handing it to `NSHostingView`. Observes
/// `AppConfig` and applies `.preferredColorScheme(_)` so the SwiftUI side of
/// AppKit-managed windows (Settings, Cloud, About, Onboarding, the floating
/// panel, live captions) re-evaluates the moment the user picks a new theme.
///
/// `ThemeManager` sets `NSApp.appearance` in parallel, which keeps AppKit
/// chrome and dynamic `NSColor`s aligned with the SwiftUI environment value.
struct ThemedHost<Content: View>: View {
    @ObservedObject private var config = AppConfig.shared
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .preferredColorScheme(config.theme.colorScheme)
    }
}
