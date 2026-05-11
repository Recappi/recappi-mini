import AppKit
import SwiftUI

extension CloudCenterPanel {
    // MARK: - Sidebar account header

    /// Top-of-sidebar account row, mirroring the Settings panel's affordance.
    /// We deliberately drive the popup from a plain `Button` + `NSMenu`
    /// instead of a SwiftUI `Menu { } label: { ... }`: on macOS, a custom
    /// Menu label with `.menuStyle(.borderlessButton)` strips inner frame
    /// and `clipShape` modifiers (the avatar would render as an unclipped
    /// full-resolution image and the subtitle/background/chevron disappear).
    /// The Button preserves the Settings-style row chrome verbatim, and
    /// `NSMenu.popUp(positioning:at:in:)` gives us a native macOS popup
    /// anchored under the row.
    var accountHeaderMenu: some View {
        Button(action: presentAccountMenu) {
            accountHeaderLabel
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.authStatus)
    }

    var accountHeaderLabel: some View {
        HStack(spacing: 10) {
            AccountAvatar(session: sessionStore.currentSession, size: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(accountHeaderTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.labelPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(accountHeaderSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.labelSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.labelTertiary)
        }
       
        .padding(.vertical, 6)
         
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    func presentAccountMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Usage section (signed in + billing loaded).
        if sessionStore.currentSession != nil, let billing = store.billingStatus {
            let header = NSMenuItem(title: "Usage", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            menu.addItem(disabledMenuItem(title: "    Storage  \(billing.storageUsageText)"))
            menu.addItem(disabledMenuItem(title: "    Minutes  \(billing.minutesUsageText)"))

            let billingItem = closureMenuItem(title: "Manage billing…", systemImage: "creditcard") { [store] in
                Task { @MainActor in await store.openBillingPortalOrPlans() }
            }
            menu.addItem(billingItem)

            menu.addItem(.separator())
        }

        // Theme submenu.
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.image = NSImage(systemSymbolName: "paintbrush", accessibilityDescription: nil)
        let themeSub = NSMenu()
        themeSub.autoenablesItems = false
        for option in AppTheme.allCases {
            let item = closureMenuItem(title: option.displayName, systemImage: nil) { [config] in
                config.theme = option
            }
            item.state = (config.theme == option) ? .on : .off
            themeSub.addItem(item)
        }
        themeItem.submenu = themeSub
        menu.addItem(themeItem)

        // Settings…
        menu.addItem(closureMenuItem(title: "Settings…", systemImage: "gear") {
            AppDelegate.shared.showSettingsWindow()
        })

        menu.addItem(.separator())

        // Sign in / sign out.
        if sessionStore.currentSession != nil {
            menu.addItem(closureMenuItem(title: "Sign out", systemImage: "rectangle.portrait.and.arrow.right") { [sessionStore, config] in
                Task { @MainActor in await sessionStore.signOut(origin: config.effectiveBackendBaseURL) }
            })
        } else {
            menu.addItem(closureMenuItem(title: "Sign in with Google", systemImage: "person.crop.circle.badge.plus") { [store] in
                Task { @MainActor in await store.signIn(with: .google) }
            })
            menu.addItem(closureMenuItem(title: "Sign in with GitHub", systemImage: "person.crop.circle.badge.plus") { [store] in
                Task { @MainActor in await store.signIn(with: .github) }
            })
        }

        // Anchor the popup under the button's frame using the current event.
        if let event = NSApp.currentEvent,
           let view = event.window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            // Fallback: pop at mouse cursor.
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private func disabledMenuItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func closureMenuItem(title: String, systemImage: String?, action: @escaping () -> Void) -> NSMenuItem {
        let target = MenuClosureTarget(action: action)
        let item = NSMenuItem(title: title, action: #selector(MenuClosureTarget.invoke), keyEquivalent: "")
        item.target = target
        item.representedObject = target  // retain
        if let symbol = systemImage {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    var accountHeaderTitle: String {
        if let session = sessionStore.currentSession {
            let name = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? session.email : name
        }
        return "Sign in"
    }

    var accountHeaderSubtitle: String {
        if let session = sessionStore.currentSession {
            return session.email
        }
        switch sessionStore.authStatus {
        case .expired:
            return "Session expired"
        case .failed:
            return "Sign in needed"
        default:
            return "Recappi Cloud"
        }
    }
}

/// Bridges a Swift closure to `NSMenuItem`'s Objective-C selector contract.
/// Retained on the menu item via `representedObject` so the closure stays
/// alive while the menu is on screen.
@MainActor
fileprivate final class MenuClosureTarget: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
    }
    @objc func invoke() {
        action()
    }
}
