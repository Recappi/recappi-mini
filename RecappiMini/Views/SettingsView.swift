import AppKit
import SwiftUI

// MARK: - Settings tab

enum SettingsItem: Hashable {
    case general
    case account
    case permissions
    case transcription
    case updates

    var fallbackContentHeight: CGFloat {
        switch self {
        case .general:
            430
        case .account:
            360
        case .permissions:
            250
        case .transcription:
            420
        case .updates:
            320
        }
    }

    /// Window title for this tab. The Settings window title follows the selected
    /// tab (System Settings style) instead of a fixed app string.
    var windowTitle: String {
        switch self {
        case .general: "General"
        case .account: "Account"
        case .permissions: "Permissions"
        case .transcription: "Transcription"
        case .updates: "About"
        }
    }
}

let settingsWindowContentWidth: CGFloat = 560
private let settingsContentWidth: CGFloat = settingsWindowContentWidth

// MARK: - Root settings view

struct SettingsView: View {
    @State private var selection: SettingsItem = .general
    @State private var capturePermissions = CapturePermissionSnapshot.placeholder
    @State private var permissionsBusy = false
    @State private var paneHeights: [SettingsItem: CGFloat] = [:]

    let ownsForegroundWindowDemand: Bool

    init(ownsForegroundWindowDemand: Bool = true) {
        self.ownsForegroundWindowDemand = ownsForegroundWindowDemand
    }

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsPage()
                .settingsPane(item: .general)
                .tabItem {
                    Label("General", systemImage: "gear")
                        .accessibilityIdentifier(AccessibilityIDs.Settings.generalTab)
                }
                .tag(SettingsItem.general)

            AccountSettingsPage()
                .settingsPane(item: .account)
                .tabItem {
                    Label("Account", systemImage: "person.crop.circle")
                        .accessibilityIdentifier(AccessibilityIDs.Settings.accountTab)
                }
                .tag(SettingsItem.account)

            PermissionsSettingsPage(
                snapshot: $capturePermissions,
                permissionsBusy: $permissionsBusy,
                onRefresh: refreshPermissionStatus
            )
            .settingsPane(item: .permissions)
            .tabItem {
                Label("Permissions", systemImage: "lock.shield")
                    .accessibilityIdentifier(AccessibilityIDs.Settings.permissionsTab)
            }
            .tag(SettingsItem.permissions)

            TranscriptionSettingsPage()
                .settingsPane(item: .transcription)
                .tabItem {
                    Label("Transcription", systemImage: "text.bubble")
                        .accessibilityIdentifier(AccessibilityIDs.Settings.transcriptionTab)
                }
                .tag(SettingsItem.transcription)

            UpdatesSettingsPage()
                .settingsPane(item: .updates)
                .tabItem {
                    Label("About", systemImage: "info.circle")
                        .accessibilityIdentifier(AccessibilityIDs.Settings.updatesTab)
                }
                .tag(SettingsItem.updates)
        }
        .frame(width: settingsWindowContentWidth)
        .navigationTitle(selection.windowTitle)
        .background(
            SettingsWindowConfigurator(
                selection: selection,
                contentHeight: currentContentHeight
            )
        )
        .onPreferenceChange(SettingsPaneHeightKey.self) { values in
            var next = paneHeights
            for (item, height) in values where height > 0 {
                next[item] = height.rounded(.up)
            }
            paneHeights = next
        }
        .task {
            refreshPermissionStatus()
        }
        .onDisappear {
            if ownsForegroundWindowDemand {
                AppDelegate.shared.releaseSettingsSceneForegroundDemand()
            }
        }
    }

    private var currentContentHeight: CGFloat {
        if let measured = paneHeights[selection], measured > 0 {
            return measured
        }
        return selection.fallbackContentHeight
    }

    // MARK: - Permissions snapshot

    private func refreshPermissionStatus() {
        capturePermissions = CapturePermissionPrimer.shared.snapshot()
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    let selection: SettingsItem
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            applyChrome(to: window)
            resize(window, contentSize: NSSize(width: settingsWindowContentWidth, height: contentHeight))
        }
    }

    private func applyChrome(to window: NSWindow) {
        // Title follows the selected tab and matches `.navigationTitle`, so the
        // imperative set and SwiftUI agree (no title flash on tab switch). The
        // old code pinned a fixed string here and re-asserted it on a deferred
        // Task, which fought SwiftUI's tab-name title and caused the flicker.
        window.title = selection.windowTitle
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .preference
        window.styleMask.remove(.resizable)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
    }

    private func resize(_ window: NSWindow, contentSize: NSSize) {
        let targetContentSize = NSSize(
            width: settingsWindowContentWidth,
            height: max(120, ceil(contentSize.height))
        )
        let frameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: targetContentSize)
        ).size
        let current = window.frame
        let target = NSRect(
            x: current.midX - frameSize.width / 2,
            y: current.maxY - frameSize.height,
            width: frameSize.width,
            height: frameSize.height
        )

        window.contentMinSize = .zero
        window.contentMaxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        window.setFrame(target, display: true, animate: false)
        window.contentMinSize = targetContentSize
        window.contentMaxSize = targetContentSize
    }
}

struct SettingsPaneHeightKey: PreferenceKey {
    static let defaultValue: [SettingsItem: CGFloat] = [:]
    static func reduce(value: inout [SettingsItem: CGFloat], nextValue: () -> [SettingsItem: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

private extension View {
    func settingsPane(item: SettingsItem) -> some View {
        self
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: settingsContentWidth, alignment: .top)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: SettingsPaneHeightKey.self, value: [item: proxy.size.height])
                }
            )
    }
}
