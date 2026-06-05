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
    ///
    /// We observe the persisted `"appTheme"` defaults key directly via KVO
    /// rather than `AppConfig.shared.objectWillChange`. `theme` is backed by
    /// `@AppStorage`, so its `$theme` projection is a SwiftUI `Binding`, not a
    /// Combine publisher — there is no per-property publisher to sink on. The
    /// only `AppConfig`-level signal is `objectWillChange`, which fires on
    /// *every* `@Published`/`@AppStorage` mutation (mic toggle, caption prefs,
    /// …). During recording those unrelated writes fan in here and wake the
    /// main queue on each one. KVO on the single `appTheme` key emits only when
    /// the theme actually changes, so unrelated config churn no longer schedules
    /// any work.
    func startObserving() {
        apply(AppConfig.shared.theme)
        guard cancellable == nil else { return }
        cancellable = UserDefaults.standard
            .publisher(for: \.appTheme)
            // Ignore an unparseable / cleared raw value rather than guessing a
            // default — the existing theme stays applied, which mirrors the old
            // guard-based behavior. The transform is pure, so it stays clear of
            // `@MainActor`-isolated state.
            .compactMap { $0.flatMap(AppTheme.init(rawValue:)) }
            .removeDuplicates()
            // Hop to the main run loop before touching `@MainActor` state, matching
            // `AppUpdater`'s KVO-publisher idiom and satisfying strict concurrency.
            .receive(on: RunLoop.main)
            .sink { [weak self] theme in
                self?.apply(theme)
            }
    }

    private func apply(_ theme: AppTheme) {
        guard lastApplied != theme else { return }
        lastApplied = theme
        NSApp.appearance = theme.nsAppearance
    }
}

/// KVO-observable bridge to the persisted theme. `@AppStorage("appTheme")`
/// reads and writes this exact key on `UserDefaults.standard`; exposing it as a
/// `@objc dynamic` property lets `publisher(for:)` deliver a change only when
/// the theme value itself is written, instead of on every defaults mutation.
extension UserDefaults {
    @objc dynamic var appTheme: String? {
        string(forKey: "appTheme")
    }
}
