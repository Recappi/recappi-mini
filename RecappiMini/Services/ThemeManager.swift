import AppKit
import Combine
import SwiftUI

/// Bridges the user's selected `AppTheme` (stored on `AppConfig`) into the
/// AppKit appearance system. Setting `NSApp.appearance` propagates to every
/// `NSWindow` / `NSPanel` that hasn't pinned its own appearance, which in
/// turn re-resolves dynamic `NSColor`s used by the SwiftUI palette.
@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    private var cancellable: AnyCancellable?
    private var lastApplied: AppTheme?

    private init() {}

    /// Wire the manager to `AppConfig`. Safe to call multiple times — only
    /// the first call installs the subscription. Apply the current value
    /// synchronously so the very first window comes up in the correct mode.
    func startObserving() {
        apply(AppConfig.shared.theme)
        guard cancellable == nil else { return }
        cancellable = AppConfig.shared.objectWillChange
            .sink { [weak self] _ in
                // `objectWillChange` fires before `@AppStorage` writes the
                // new value; defer one runloop tick so we read the latest.
                DispatchQueue.main.async {
                    self?.apply(AppConfig.shared.theme)
                }
            }
    }

    private func apply(_ theme: AppTheme) {
        guard lastApplied != theme else { return }
        lastApplied = theme
        NSApp.appearance = theme.nsAppearance
    }
}
