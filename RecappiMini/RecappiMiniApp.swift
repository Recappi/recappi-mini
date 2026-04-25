import AppKit
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
        // Standalone Settings window — opened via ⌘, or the gear in the panel.
        // .contentSize makes the window track the SwiftUI content's intrinsic
        // size so settings sections can grow without forcing an internal
        // scroll view.
        Settings {
            SettingsView()
        }
        .windowResizability(.contentSize)
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
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, NSWindowDelegate, NSMenuDelegate {
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

    private var statusItem: NSStatusItem?
    private var recordingDotView: NSView?
    private var showHidePanelMenuItem: NSMenuItem?
    private var checkForUpdatesMenuItem: NSMenuItem?
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
    private var detectedMeetingAutoStopTask: Task<Void, Never>?
    private var runningAppsRefreshTask: Task<Void, Never>?
    private var runningAppsRefreshGeneration = 0
    private var recorderStateObserver: AnyCancellable?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenParametersObserver: NSObjectProtocol?
    private var panelTransitionToken: Int = 0
    private var uiTestCommandPollTimer: Timer?
    private var didFinishLaunching = false
    private var uiTestMeetingLabelByBundleID: [String: String] = [:]
    private var panelTargetVisible = true {
        didSet {
            panelVisible = panelTargetVisible
        }
    }

    /// Tracks whether the user wants the floating panel shown so tray menus
    /// don't mistake a warm offscreen panel for an interactive one.
    @Published var panelVisible: Bool = true
    @Published private(set) var isRecording: Bool = false

    private var effectiveActiveAudioBundleIDs: Set<String> {
        Set(recorder.runningApps.lazy.filter(\.isActive).map(\.id))
    }

    private var hiddenAutoPromptSnoozeDuration: TimeInterval {
        uiTestMode.hiddenAutoPromptSnoozeSeconds ?? 6
    }

    private var detectedMeetingAutoStopGraceDuration: TimeInterval {
        uiTestMode.detectedMeetingAutoStopGraceSeconds ?? 8
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
        installStatusItemIfNeeded()
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

        let hostingView = NSHostingView(
            rootView: FloatingPanelChromeView {
                contentView
            }
        )
        hostingView.sizingOptions = [.intrinsicContentSize]

        // AppKit only measures and hosts; SwiftUI owns the rounded chrome,
        // shadow, and show/hide motion so panel transitions stay compositor-friendly.
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
        installScreenParameterObserver()
        installUITestCommandPollingIfNeeded()
        recorder.refreshAppsFromWorkspaceSnapshot()

        Task {
            await recorder.refreshApps(seedFromWorkspace: false)
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
                    self.recorder.applyActivity(active)
                    self.handleActiveAudioChanged(self.effectiveActiveAudioBundleIDs)
                }
            }
        recorderStateObserver = recorder.$state
            .map(\.isRecording)
            .removeDuplicates()
            .sink { [weak self] isRecording in
                guard let self else { return }
                self.isRecording = isRecording
                self.updateStatusItemRecordingState(isRecording)
            }
    }

    func applicationWillTerminate(_ notification: Notification) {
        activePromptRefreshTask?.cancel()
        browserAutoPromptTask?.cancel()
        hiddenPanelAutoPromptTask?.cancel()
        detectedMeetingAutoStopTask?.cancel()
        runningAppsRefreshTask?.cancel()
        recorderStateObserver?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        uiTestCommandPollTimer?.invalidate()
        uiTestCommandPollTimer = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.image = MenuBarIconFactory.idleIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "Recappi Mini"

            let dot = StatusRecordingDotView(frame: .zero)
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            dot.layer?.cornerRadius = 1.9
            dot.layer?.contentsScale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            dot.isHidden = true
            button.addSubview(dot)
            recordingDotView = dot
            positionRecordingDot()
        }

        let menu = NSMenu()
        menu.delegate = self

        let showHide = NSMenuItem(
            title: "Show Panel",
            action: #selector(togglePanelFromStatusMenu),
            keyEquivalent: ""
        )
        showHide.target = self
        showHidePanelMenuItem = showHide
        menu.addItem(showHide)

        let cloud = NSMenuItem(
            title: "Recappi Cloud…",
            action: #selector(showCloudCenterFromStatusMenu),
            keyEquivalent: ""
        )
        cloud.target = self
        menu.addItem(cloud)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsFromStatusMenu),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let updates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesFromStatusMenu),
            keyEquivalent: ""
        )
        updates.target = self
        checkForUpdatesMenuItem = updates
        menu.addItem(updates)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(quitFromStatusMenu),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        updateStatusMenuItems()
    }

    private func positionRecordingDot() {
        guard let button = statusItem?.button, let dot = recordingDotView else { return }
        let iconSize: CGFloat = 18
        let dotSize: CGFloat = 3.8
        let iconOrigin = CGPoint(
            x: button.bounds.midX - iconSize / 2,
            y: button.bounds.midY - iconSize / 2
        )
        // The logo is a 36px template scaled to 18pt. The face points right;
        // these ratios put the recording dot on the nose instead of as a
        // generic status badge.
        let center = CGPoint(
            x: iconOrigin.x + iconSize * 0.92,
            y: iconOrigin.y + iconSize * 0.58
        )
        let originY = button.isFlipped
            ? button.bounds.height - center.y - dotSize / 2
            : center.y - dotSize / 2
        dot.frame = CGRect(
            x: center.x - dotSize / 2,
            y: originY,
            width: dotSize,
            height: dotSize
        )
    }

    private func updateStatusItemRecordingState(_ isRecording: Bool) {
        positionRecordingDot()
        recordingDotView?.isHidden = !isRecording
        if isRecording {
            startRecordingDotPulse()
        } else {
            stopRecordingDotPulse()
        }
    }

    private func startRecordingDotPulse() {
        guard let layer = recordingDotView?.layer else { return }
        guard layer.animation(forKey: "recappi.recordingDotPulse") == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.42
        animation.duration = 0.9
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "recappi.recordingDotPulse")
    }

    private func stopRecordingDotPulse() {
        guard let layer = recordingDotView?.layer else { return }
        layer.removeAnimation(forKey: "recappi.recordingDotPulse")
        layer.opacity = 1
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateStatusMenuItems()
    }

    private func updateStatusMenuItems() {
        showHidePanelMenuItem?.title = panelVisible ? "Hide Panel" : "Show Panel"
        checkForUpdatesMenuItem?.isEnabled = appUpdater.canCheckForUpdates
    }

    @objc private func togglePanelFromStatusMenu() {
        togglePanel()
        updateStatusMenuItems()
    }

    @objc private func showCloudCenterFromStatusMenu() {
        showCloudCenter()
    }

    @objc private func openSettingsFromStatusMenu() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func checkForUpdatesFromStatusMenu() {
        appUpdater.checkForUpdates()
    }

    @objc private func quitFromStatusMenu() {
        NSApp.terminate(nil)
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
        panelTargetVisible = true
        // Showing the lightweight recorder panel should not flip the app into
        // regular activation mode. That transition is surprisingly expensive
        // and makes the slide feel hitchy; reserve it for Settings/Cloud/OAuth.
        NSApp.unhide(nil)
        if activateApp {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
        }
        if FloatingPanelController.isPresented(panel) {
            bringPanelToFront(panel, activateApp: activateApp)
            syncPanelVisibility()
            refreshRunningApps()
        } else {
            panelVisible = true
            FloatingPanelController.present(panel) { [weak self] in
                guard let self else { return }
                guard self.panelTransitionToken == transitionToken else { return }
                self.bringPanelToFront(panel, activateApp: activateApp)
                self.syncPanelVisibility()
                self.refreshRunningApps()
            }
        }
        schedulePanelPresentationVerification(for: transitionToken, activateApp: activateApp)
    }

    func hidePanel() {
        guard let panel else { return }
        guard panelTargetVisible || panel.isVisible || FloatingPanelController.isPresented(panel) else { return }
        panelTransitionToken += 1
        let transitionToken = panelTransitionToken
        panelTargetVisible = false
        panelVisible = false
        FloatingPanelController.dismiss(panel) { [weak self] in
            guard let self else { return }
            guard self.panelTransitionToken == transitionToken else { return }
            guard self.panelTargetVisible == false else { return }
            self.syncPanelVisibility()
            self.restoreAccessoryActivationPolicyIfPossible()
            self.scheduleHiddenPanelAutoPromptIfNeeded()
        }
    }

    func togglePanel() {
        if panelTargetVisible {
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

    private func installScreenParameterObserver() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChanged()
            }
        }
    }

    private func handleScreenParametersChanged() {
        guard let panel else { return }
        if panelTargetVisible {
            FloatingPanelController.snapToVisible(panel)
            bringPanelToFront(panel, activateApp: false)
            syncPanelVisibility()
        } else {
            FloatingPanelController.snapToHidden(panel)
            panelVisible = false
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

    private func installUITestAutoPromptIfNeeded() {
        guard let simulated = uiTestMode.simulatedAutoPromptApp else { return }
        recorder.injectUITestAudioApp(bundleID: simulated.bundleID, name: simulated.name)
        let active = Set([simulated.bundleID])
        recorder.applyActivity(active)
        handleActiveAudioChanged(active)
    }

    private func handleActiveAudioChanged(_ active: Set<String>) {
        handleDetectedMeetingRecordingActivity(active)
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
            await self.recorder.refreshApps(seedFromWorkspace: false)
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

    private func handleDetectedMeetingRecordingActivity(_ active: Set<String>) {
        guard let context = recorder.detectedMeetingRecordingContext,
              recorder.state == .recording else {
            detectedMeetingAutoStopTask?.cancel()
            detectedMeetingAutoStopTask = nil
            return
        }

        let targetID = BundleCollapser.parent(of: context.appID)
        guard !active.contains(targetID) else {
            detectedMeetingAutoStopTask?.cancel()
            detectedMeetingAutoStopTask = nil
            return
        }

        guard detectedMeetingAutoStopTask == nil else { return }
        let grace = detectedMeetingAutoStopGraceDuration
        detectedMeetingAutoStopTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(grace))
                guard !Task.isCancelled else { return }
                guard self.recorder.state == .recording,
                      let current = self.recorder.detectedMeetingRecordingContext,
                      current.appID == context.appID else {
                    self.detectedMeetingAutoStopTask = nil
                    return
                }

                let latestActive = self.effectiveActiveAudioBundleIDs
                guard !latestActive.contains(targetID) else {
                    self.detectedMeetingAutoStopTask = nil
                    return
                }

                if await self.browserMeetingStillLooksActive(current) {
                    continue
                }

                self.recorder.requestAutoStopForDetectedMeetingIfNeeded()
                self.detectedMeetingAutoStopTask = nil
                return
            }
        }
    }

    private func browserMeetingStillLooksActive(_ context: DetectedMeetingRecordingContext) async -> Bool {
        guard BrowserMeetingDetector.supports(bundleID: context.appID) else { return false }
        if meetingLabelOverride(for: context.appID) != nil {
            return true
        }
        return await BrowserMeetingDetector.inferMeetingSuggestion(
            bundleID: context.appID,
            browserName: context.appName
        ) != nil
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

        // Prepare the prompt content before the panel starts sliding in. If we
        // mutate SwiftUI state mid-flight, the hosting view reports a new
        // intrinsic height and AppKit has to resize the window during motion.
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

        showPanel(activateApp: false)
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
        guard effectiveActiveAudioBundleIDs.contains(bundleID) else { return nil }
        guard let override = uiTestMode.simulatedAutoPromptMeetingLabel, !override.isEmpty else { return nil }
        return override
    }

    private func consumeUITestCommandIfNeeded(at url: URL) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        try? FileManager.default.removeItem(at: url)
        guard let command = try? JSONDecoder().decode(UITestAutoPromptCommand.self, from: data) else { return }

        if !command.active {
            uiTestMeetingLabelByBundleID.removeValue(forKey: command.bundleID)
            let appName = command.appName.isEmpty ? command.bundleID : command.appName
            recorder.setUITestAudioApp(bundleID: command.bundleID, name: appName, active: false)
            let active = effectiveActiveAudioBundleIDs
            recorder.applyActivity(active)
            handleActiveAudioChanged(active)
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

        recorder.setUITestAudioApp(bundleID: bundleID, name: appName, active: true)
        let active = Set([bundleID])
        recorder.applyActivity(active)
        handleActiveAudioChanged(active)
    }

    private func refreshRunningApps() {
        recorder.refreshAppsFromWorkspaceSnapshot()
        runningAppsRefreshGeneration += 1
        let generation = runningAppsRefreshGeneration
        runningAppsRefreshTask?.cancel()
        runningAppsRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            await self.recorder.refreshApps(seedFromWorkspace: false)
            guard !Task.isCancelled, self.runningAppsRefreshGeneration == generation else { return }
            self.runningAppsRefreshTask = nil
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
            guard self.panelTargetVisible == false else { return }
            guard AppConfig.shared.autoPromptForActiveAudioApps else { return }
            guard self.recorder.state == .idle else { return }

            let active = self.effectiveActiveAudioBundleIDs
            guard !active.isEmpty else { return }

            self.recorder.refreshAppsFromWorkspaceSnapshot()
            if self.promptForMeetingAudioIfNeeded(active) { return }

            await self.recorder.refreshApps(seedFromWorkspace: false)
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
        guard !panel.isFloatingTransitioning else { return }

        guard panelTargetVisible else {
            FloatingPanelController.snapToHidden(panel)
            panelVisible = false
            return
        }

        let isShown = FloatingPanelController.isPresented(panel)
        if isShown && panel.ignoresMouseEvents {
            panel.ignoresMouseEvents = false
        }
        panelVisible = panelTargetVisible
    }

    private func bringPanelToFront(_ panel: FloatingPanel, activateApp: Bool) {
        if activateApp {
            NSApp.unhide(nil)
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.orderFrontRegardless()
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
            guard !panel.isFloatingTransitioning else { return }
            guard self.panelTargetVisible else {
                FloatingPanelController.snapToHidden(panel)
                self.panelVisible = false
                return
            }
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
