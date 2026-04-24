import Combine
import SwiftUI

@main
struct RecappiMiniApp: App {
    @StateObject private var appDelegate = AppDelegate.shared

    init() {
        DispatchQueue.main.async {
            AppDelegate.shared.finishLaunchingIfNeeded()
        }
    }

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

        Button("Recappi Cloud…") {
            appDelegate.showCloudCenter()
        }

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
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, NSWindowDelegate {
    static let shared = AppDelegate()

    private struct UITestAutoPromptCommand: Decodable {
        let bundleID: String
        let appName: String
        let meetingLabel: String?
        let active: Bool
    }

    private struct AutoPromptTarget: Sendable {
        let app: AudioApp
        let promptKey: String
        let promptTitle: String?
    }

    private var panel: FloatingPanel?
    private var cloudWindow: NSWindow?
    private let recorder = AudioRecorder()
    private let appUpdater = AppUpdater.shared
    private let uiTestMode = UITestModeConfiguration.shared
    private var activityObserver: AnyCancellable?
    private var promptedAutoPromptKeyByBundleID: [String: String] = [:]
    private var activePromptRefreshTask: Task<Void, Never>?
    private var browserAutoPromptTask: Task<Void, Never>?
    private var hiddenPanelAutoPromptTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var panelTransitionToken: Int = 0
    private var uiTestCommandPollTimer: Timer?
    private var didFinishLaunching = false
    private var uiTestMeetingLabelByBundleID: [String: String] = [:]

    /// Tracks whether the floating panel is currently on-screen so the
    /// MenuBarExtra can flip its label between Show / Hide. Published so
    /// the SwiftUI menu re-renders when we toggle.
    @Published var panelVisible: Bool = true

    private var effectiveActiveAudioBundleIDs: Set<String> {
        Set(recorder.runningApps.lazy.filter(\.isActive).map(\.id)).union(simulatedUITestActiveBundleIDs)
    }

    private var hiddenAutoPromptSnoozeDuration: TimeInterval {
        uiTestMode.hiddenAutoPromptSnoozeSeconds ?? 6
    }

    private var browserMeetingPollInterval: TimeInterval {
        uiTestMode.isEnabled ? 0.25 : 2.0
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishLaunchingIfNeeded()
    }

    func finishLaunchingIfNeeded() {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            await AuthSessionStore.shared.bootstrapForUITestsIfNeeded()
            if self.uiTestMode.openCloudWindowOnLaunch {
                self.showCloudCenter()
            }
        }
        appUpdater.start()

        let m = PillShellView.shadowMargin
        let pillWidth = DT.panelWidth
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: pillWidth + m * 2, height: 56 + m * 2))

        let contentView = RecordingPanel(
            recorder: recorder,
            onOpenFolder: { folderURL in NSWorkspace.shared.open(folderURL) },
            onClosePanel: { [weak self] in self?.hidePanel() }
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.sizingOptions = [.intrinsicContentSize]

        // AppKit shell owns the rounded chrome + shadow via CALayer so
        // the drop shadow is reliable and traces the rounded shape.
        let shell = PillShellView(frame: NSRect(x: 0, y: 0, width: 280 + m * 2, height: 56 + m * 2))
        shell.setContent(hostingView)
        panel.contentView = shell
        panel.delegate = self
        FloatingPanelController.positionAtTopRight(panel, width: pillWidth, height: 56)
        panel.orderFrontRegardless()

        self.panel = panel
        syncPanelVisibility()
        schedulePanelPresentationVerification(for: panelTransitionToken, activateApp: false)

        installWorkspaceObservers()
        installUITestCommandPollingIfNeeded()
        recorder.refreshAppsFromWorkspaceSnapshot()

        Task {
            await recorder.refreshApps()
        }

        installUITestAutoPromptIfNeeded()

        // Hot-audio detection: start the CoreAudio poll and re-sort the
        // picker each time the active set changes so apps currently making
        // sound float to the top.
        recorder.activityMonitor.start()
        activityObserver = recorder.activityMonitor
            .$activeBundleIDs
            .sink { [weak self] active in
                Task { @MainActor in
                    guard let self else { return }
                    let effectiveActive = active.union(self.simulatedUITestActiveBundleIDs)
                    self.recorder.applyActivity(effectiveActive)
                    self.handleActiveAudioChanged(effectiveActive)
                }
            }
    }

    func applicationWillTerminate(_ notification: Notification) {
        activePromptRefreshTask?.cancel()
        browserAutoPromptTask?.cancel()
        hiddenPanelAutoPromptTask?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        uiTestCommandPollTimer?.invalidate()
        uiTestCommandPollTimer = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func showPanel(activateApp: Bool = false) {
        guard let panel else { return }
        panelTransitionToken += 1
        let transitionToken = panelTransitionToken
        hiddenPanelAutoPromptTask?.cancel()
        hiddenPanelAutoPromptTask = nil
        NSApp.setActivationPolicy(.regular)
        if activateApp {
            NSApp.unhide(nil)
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
        }
        if FloatingPanelController.isPresented(panel) {
            bringPanelToFront(panel, activateApp: false)
            syncPanelVisibility()
        } else {
            panelVisible = true
            FloatingPanelController.present(panel) { [weak self] in
                guard let self else { return }
                guard self.panelTransitionToken == transitionToken else { return }
                self.bringPanelToFront(panel, activateApp: false)
                self.syncPanelVisibility()
            }
        }
        schedulePanelPresentationVerification(for: transitionToken, activateApp: activateApp)
        refreshRunningApps()
    }

    func hidePanel() {
        guard let panel else { return }
        guard panelVisible || panel.isVisible || FloatingPanelController.isPresented(panel) else { return }
        panelTransitionToken += 1
        let transitionToken = panelTransitionToken
        panelVisible = false
        FloatingPanelController.dismiss(panel) { [weak self] in
            guard let self else { return }
            guard self.panelTransitionToken == transitionToken else { return }
            guard self.panelVisible == false else { return }
            panel.orderOut(nil)
            self.syncPanelVisibility()
            self.restoreAccessoryActivationPolicyIfPossible()
            self.scheduleHiddenPanelAutoPromptIfNeeded()
        }
    }

    func togglePanel() {
        if panelVisible || (panel.map(FloatingPanelController.isPresented) ?? false) {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func quitApp() {
        NSApp.terminate(nil)
    }

    func showCloudCenter() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)

        if let cloudWindow {
            cloudWindow.makeKeyAndOrderFront(nil)
            return
        }

        let hostingView = NSHostingView(rootView: CloudCenterPanel())
        hostingView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Recappi Cloud"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 700, height: 600)
        window.contentView = hostingView
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        cloudWindow = window
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

    private func installUITestCommandPollingIfNeeded() {
        guard uiTestMode.isEnabled else { return }
        guard let commandFilePath = uiTestMode.commandFilePath, !commandFilePath.isEmpty else { return }

        let commandFileURL = URL(fileURLWithPath: commandFilePath)
        uiTestCommandPollTimer?.invalidate()
        uiTestCommandPollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.consumeUITestCommandIfNeeded(at: commandFileURL)
            }
        }
        uiTestCommandPollTimer?.tolerance = 0.05
    }

    private var simulatedUITestActiveBundleIDs: Set<String> {
        guard let simulated = uiTestMode.simulatedAutoPromptApp else { return [] }
        return [simulated.bundleID]
    }

    private func installUITestAutoPromptIfNeeded() {
        guard let simulated = uiTestMode.simulatedAutoPromptApp else { return }
        recorder.injectUITestAudioApp(bundleID: simulated.bundleID, name: simulated.name)
        let active = simulatedUITestActiveBundleIDs
        recorder.applyActivity(active)
        handleActiveAudioChanged(active)
    }

    private func handleActiveAudioChanged(_ active: Set<String>) {
        promptedAutoPromptKeyByBundleID = promptedAutoPromptKeyByBundleID.filter { active.contains($0.key) }

        guard AppConfig.shared.autoPromptForActiveAudioApps else {
            browserAutoPromptTask?.cancel()
            recorder.clearRecordingSuggestion()
            return
        }
        guard !active.isEmpty else {
            browserAutoPromptTask?.cancel()
            recorder.clearRecordingSuggestion()
            return
        }
        guard recorder.state == .idle else {
            browserAutoPromptTask?.cancel()
            return
        }

        recorder.refreshAppsFromWorkspaceSnapshot()
        if promptForMeetingAudioIfNeeded(active) {
            browserAutoPromptTask?.cancel()
            return
        }

        scheduleBrowserMeetingAutoPromptIfNeeded(active)

        activePromptRefreshTask?.cancel()
        activePromptRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.recorder.refreshApps()
            guard !Task.isCancelled else { return }
            let latestActive = self.effectiveActiveAudioBundleIDs
            self.recorder.applyActivity(latestActive)
            if self.promptForMeetingAudioIfNeeded(latestActive) {
                self.browserAutoPromptTask?.cancel()
                return
            }
            self.scheduleBrowserMeetingAutoPromptIfNeeded(latestActive)
        }
    }

    @discardableResult
    private func promptForMeetingAudioIfNeeded(_ active: Set<String>) -> Bool {
        guard recorder.state == .idle else { return false }
        guard let app = AudioRecorder.autoPromptCandidate(from: recorder.runningApps, active: active) else { return false }
        let target = AutoPromptTarget(app: app, promptKey: "meeting:\(app.id)", promptTitle: nil)
        return presentAutoPromptIfNeeded(target)
    }

    @discardableResult
    private func presentAutoPromptIfNeeded(_ target: AutoPromptTarget) -> Bool {
        guard recorder.state == .idle else { return false }
        guard promptedAutoPromptKeyByBundleID[target.app.id] != target.promptKey else { return false }

        let wasPanelHidden = !(panel.map(FloatingPanelController.isPresented) ?? false)
        promptedAutoPromptKeyByBundleID[target.app.id] = target.promptKey
        showPanel(activateApp: true)
        if wasPanelHidden {
            recorder.selectApp(target.app, clearPrompts: false)
            recorder.clearRecordingSuggestion()
            recorder.showMeetingPrompt(
                for: target.app,
                promptTitle: target.promptTitle ?? target.app.name
            )
        } else if let promptTitle = target.promptTitle {
            recorder.suggestRecording(for: target.app, promptTitle: promptTitle)
        } else {
            recorder.suggestRecording(for: target.app)
        }
        return true
    }

    private func scheduleBrowserMeetingAutoPromptIfNeeded(_ active: Set<String>) {
        browserAutoPromptTask?.cancel()

        let activeBrowsers = recorder.runningApps
            .filter { active.contains($0.id) && $0.bucket == .browser }
            .sorted(by: AudioRecorder.sortOrder)
        guard !activeBrowsers.isEmpty else { return }

        browserAutoPromptTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard AppConfig.shared.autoPromptForActiveAudioApps else { return }
                guard self.recorder.state == .idle else { return }

                let latestActive = self.effectiveActiveAudioBundleIDs
                guard !latestActive.isEmpty else { return }

                if let target = await self.resolveBrowserMeetingAutoPrompt(from: latestActive) {
                    _ = self.presentAutoPromptIfNeeded(target)
                    return
                }

                try? await Task.sleep(for: .seconds(self.browserMeetingPollInterval))
            }
        }
    }

    private func resolveBrowserMeetingAutoPrompt(from active: Set<String>) async -> AutoPromptTarget? {
        let candidates = recorder.runningApps
            .filter { active.contains($0.id) && $0.bucket == .browser }
            .sorted(by: AudioRecorder.sortOrder)

        for app in candidates {
            if let promptTitle = meetingLabelOverride(for: app.id) {
                return AutoPromptTarget(
                    app: app,
                    promptKey: "browser:\(app.id):\(promptTitle)",
                    promptTitle: promptTitle
                )
            }

            guard BrowserMeetingDetector.supports(bundleID: app.id) else { continue }
            guard let promptTitle = await BrowserMeetingDetector.inferMeetingSuggestion(
                bundleID: app.id,
                browserName: app.name
            ) else { continue }

            return AutoPromptTarget(
                app: app,
                promptKey: "browser:\(app.id):\(promptTitle)",
                promptTitle: promptTitle
            )
        }

        return nil
    }

    private func meetingLabelOverride(for bundleID: String) -> String? {
        if let override = uiTestMeetingLabelByBundleID[bundleID], !override.isEmpty {
            return override
        }
        guard uiTestMode.simulatedAutoPromptApp?.bundleID == bundleID else { return nil }
        guard let override = uiTestMode.simulatedAutoPromptMeetingLabel, !override.isEmpty else { return nil }
        return override
    }

    private func consumeUITestCommandIfNeeded(at url: URL) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        try? FileManager.default.removeItem(at: url)
        guard let command = try? JSONDecoder().decode(UITestAutoPromptCommand.self, from: data) else { return }

        if !command.active {
            uiTestMeetingLabelByBundleID.removeValue(forKey: command.bundleID)
            recorder.applyActivity([])
            handleActiveAudioChanged([])
            return
        }

        let bundleID = command.bundleID
        guard !bundleID.isEmpty else { return }
        let appName = command.appName.isEmpty ? bundleID : command.appName
        let meetingLabel = command.meetingLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let meetingLabel, !meetingLabel.isEmpty {
            uiTestMeetingLabelByBundleID[bundleID] = meetingLabel
        } else {
            uiTestMeetingLabelByBundleID.removeValue(forKey: bundleID)
        }

        recorder.injectUITestAudioApp(bundleID: bundleID, name: appName)
        let active = Set([bundleID])
        recorder.applyActivity(active)
        handleActiveAudioChanged(active)
    }

    private func refreshRunningApps() {
        recorder.refreshAppsFromWorkspaceSnapshot()
        Task {
            await recorder.refreshApps()
        }
    }

    private func scheduleHiddenPanelAutoPromptIfNeeded() {
        hiddenPanelAutoPromptTask?.cancel()
        hiddenPanelAutoPromptTask = nil

        guard AppConfig.shared.autoPromptForActiveAudioApps else { return }
        guard recorder.state == .idle else { return }

        let activeAtHide = effectiveActiveAudioBundleIDs
        guard !activeAtHide.isEmpty else { return }

        for bundleID in activeAtHide {
            promptedAutoPromptKeyByBundleID.removeValue(forKey: bundleID)
        }
        let snoozeDuration = hiddenAutoPromptSnoozeDuration

        hiddenPanelAutoPromptTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(snoozeDuration))
            guard !Task.isCancelled else { return }
            guard self.panelVisible == false else { return }
            guard AppConfig.shared.autoPromptForActiveAudioApps else { return }
            guard self.recorder.state == .idle else { return }

            let active = self.effectiveActiveAudioBundleIDs
            guard !active.isEmpty else { return }

            self.recorder.refreshAppsFromWorkspaceSnapshot()
            if self.promptForMeetingAudioIfNeeded(active) { return }

            await self.recorder.refreshApps()
            guard !Task.isCancelled else { return }

            let latestActive = self.effectiveActiveAudioBundleIDs
            self.recorder.applyActivity(latestActive)
            if self.promptForMeetingAudioIfNeeded(latestActive) { return }
            if let target = await self.resolveBrowserMeetingAutoPrompt(from: latestActive) {
                _ = self.presentAutoPromptIfNeeded(target)
            }
        }
    }

    private func syncPanelVisibility() {
        guard let panel else {
            panelVisible = false
            return
        }

        let isShown = FloatingPanelController.isPresented(panel)
        let isUserVisible = isShown && (panel.occlusionState.contains(.visible) || panel.isKeyWindow)
        panelVisible = isUserVisible
    }

    private func bringPanelToFront(_ panel: FloatingPanel, activateApp: Bool) {
        if activateApp {
            NSApp.unhide(nil)
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    private func restoreAccessoryActivationPolicyIfPossible() {
        let hasVisibleSettingsWindow = NSApp.windows.contains { window in
            window.isVisible && window.title.localizedCaseInsensitiveContains("settings")
        }
        let hasVisibleCloudWindow = cloudWindow?.isVisible == true
        guard !hasVisibleSettingsWindow && !hasVisibleCloudWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func schedulePanelPresentationVerification(for token: Int, activateApp: Bool) {
        guard let panel else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard let self else { return }
            guard self.panelTransitionToken == token else { return }
            let isShown = FloatingPanelController.isPresented(panel)
            let isOccluded = !panel.occlusionState.contains(.visible) && !panel.isKeyWindow
            guard !isShown || (activateApp && isOccluded) else {
                self.syncPanelVisibility()
                return
            }

            self.bringPanelToFront(panel, activateApp: activateApp)
            FloatingPanelController.snapToVisible(panel)
            self.syncPanelVisibility()
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        syncPanelVisibility()
    }

    func windowDidMove(_ notification: Notification) {
        syncPanelVisibility()
    }

    func windowDidResize(_ notification: Notification) {
        syncPanelVisibility()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        syncPanelVisibility()
    }

    func windowDidResignKey(_ notification: Notification) {
        syncPanelVisibility()
    }

    func windowDidExpose(_ notification: Notification) {
        syncPanelVisibility()
    }

    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow, closingWindow === cloudWindow {
            cloudWindow = nil
            restoreAccessoryActivationPolicyIfPossible()
        }
    }
}
