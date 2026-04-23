import Combine
import SwiftUI

@main
struct RecappiMiniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Use the `label:` form with an explicitly-loaded NSImage whose
        // `isTemplate = true` is set by us. `MenuBarExtra(_:image:)` with
        // a string name does NOT respect the Template filename convention
        // for loose bundle PNGs — so we bypass the string lookup and pass
        // a pre-flagged NSImage directly.
        MenuBarExtra {
            MenuBarContents(appDelegate: appDelegate)
        } label: {
            Image(nsImage: menuBarIcon)
        }

        // Standalone Settings window — opened via ⌘, or the gear in the panel.
        // .contentSize makes the window track the SwiftUI content's intrinsic
        // size so settings sections can grow without forcing an internal
        // scroll view.
        Settings {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }

    /// Menu-bar icon. Loaded from `Contents/Resources/LogoTemplate.png`
    /// with `isTemplate = true` so macOS tints the silhouette to match
    /// the menu-bar color (light/dark, vibrancy). Size is explicit 18pt
    /// so the 36pt source is downsampled to the standard menu-bar height
    /// instead of overflowing the bar.
    private var menuBarIcon: NSImage {
        let image = Bundle.main.url(forResource: "LogoTemplate", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(named: "LogoTemplate")
            ?? NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Recappi Mini")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}

struct MenuBarContents: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject private var appUpdater = AppUpdater.shared
    // `SettingsLink` won't bring the Settings window forward while the app
    // is in `.accessory` activation mode (which we have to be in so the
    // floating panel can coexist without a dock icon). Use the env-provided
    // `openSettings` after temporarily promoting to `.regular`, same trick
    // the in-panel gear button uses. `SettingsView.onDisappear` flips it
    // back to `.accessory`.
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(appDelegate.panelVisible ? "Hide Panel" : "Show Panel") {
            appDelegate.togglePanel()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Button("Settings…") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button("Check for Updates…") {
            appUpdater.checkForUpdates()
        }
        .disabled(!appUpdater.canCheckForUpdates)

        Divider()

        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var panel: FloatingPanel?
    private let recorder = AudioRecorder()
    private let appUpdater = AppUpdater.shared
    private var activityObserver: AnyCancellable?
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Tracks whether the floating panel is currently on-screen so the
    /// MenuBarExtra can flip its label between Show / Hide. Published so
    /// the SwiftUI menu re-renders when we toggle.
    @Published var panelVisible: Bool = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { await AuthSessionStore.shared.bootstrapForUITestsIfNeeded() }
        Task { await CapturePermissionPrimer.shared.primeIfNeeded() }
        appUpdater.start()

        let m = PillShellView.shadowMargin
        let pillWidth = DT.panelWidth
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: pillWidth + m * 2, height: 56 + m * 2))

        let contentView = RecordingPanel(
            recorder: recorder,
            onOpenFolder: { folderURL in NSWorkspace.shared.open(folderURL) },
            onClosePanel: { [weak self] in self?.quitApp() }
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.sizingOptions = [.intrinsicContentSize]

        // AppKit shell owns the rounded chrome + shadow via CALayer so
        // the drop shadow is reliable and traces the rounded shape.
        let shell = PillShellView(frame: NSRect(x: 0, y: 0, width: 280 + m * 2, height: 56 + m * 2))
        shell.setContent(hostingView)
        panel.contentView = shell
        FloatingPanelController.positionAtTopRight(panel, width: pillWidth, height: 56)
        panel.orderFrontRegardless()

        self.panel = panel

        installWorkspaceObservers()
        recorder.refreshAppsFromWorkspaceSnapshot()

        Task {
            await recorder.refreshApps()
        }

        // Hot-audio detection: start the CoreAudio poll and re-sort the
        // picker each time the active set changes so apps currently making
        // sound float to the top.
        recorder.activityMonitor.start()
        activityObserver = recorder.activityMonitor
            .$activeBundleIDs
            .sink { [weak self] active in
                Task { @MainActor in
                    self?.recorder.applyActivity(active)
                }
            }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func showPanel() {
        panel?.orderFrontRegardless()
        panelVisible = true
        refreshRunningApps()
    }

    func hidePanel() {
        panel?.orderOut(nil)
        panelVisible = false
    }

    func togglePanel() {
        if panelVisible { hidePanel() } else { showPanel() }
    }

    func quitApp() {
        NSApp.terminate(nil)
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]

        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshRunningApps()
                }
            }
        }
    }

    private func refreshRunningApps() {
        recorder.refreshAppsFromWorkspaceSnapshot()
        Task {
            await recorder.refreshApps()
        }
    }
}
