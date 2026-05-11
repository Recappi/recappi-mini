import AppKit
import Combine
import SwiftUI
@preconcurrency import UserNotifications

@main
struct RecappiMiniApp: App {
    private static let isRunningForPreviews =
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

    init() {
        // SwiftUI Previews on Xcode 26 launch the full @main app under a
        // preview shell. Booting AppDelegate would spin up the recorder,
        // Sparkle, status item, etc. and abort in the sandboxed preview
        // process. Skip the boot path entirely when previewing — every
        // singleton (`AppConfig.shared`, `AuthSessionStore.shared`,
        // `AppUpdater.shared`) is lazy and can still answer reads.
        guard !Self.isRunningForPreviews else { return }
        let appDelegate = AppDelegate.shared
        DispatchQueue.main.async {
            appDelegate.finishLaunchingIfNeeded()
        }
    }

    var body: some Scene {
        // Standalone Settings window — opened via ⌘, or the gear in the panel.
        // The sidebar+detail layout has no intrinsic width, so we constrain
        // resizability with `.contentMinSize` and let the NavigationSplitView
        // hold its 720×520 minimum from inside the SwiftUI tree.
        Settings {
            settingsRoot
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Replace the system's standard "About Recappi Mini" menu item
            // (which opens `orderFrontStandardAboutPanel(_:)`) so the menu
            // bar surfaces our custom AboutRecappiMiniView instead.
            CommandGroup(replacing: .appInfo) {
                Button("About Recappi Mini") {
                    AppDelegate.shared.showAboutPanel()
                }
            }
        }
    }

    @ViewBuilder
    private var settingsRoot: some View {
        if Self.isRunningForPreviews {
            // SwiftUI builds the Settings scene's content tree at app start,
            // which would eagerly evaluate `AppUpdater.shared` (Sparkle) and
            // friends. Sparkle's SPUStandardUpdaterController init aborts
            // under the preview shell, so we short-circuit to an empty
            // placeholder when running for previews.
            EmptyView()
        } else {
            ThemedHost {
                SettingsView()
                    .environmentObject(AppConfig.shared)
                    .environmentObject(AuthSessionStore.shared)
                    .environmentObject(AppUpdater.shared)
            }
        }
    }

}
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, NSWindowDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
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
    private let managedWindows = ManagedWindowRegistry()
    private lazy var foregroundWindows = ForegroundWindowActivationCoordinator(managedWindows: managedWindows)
    private let cloudStore = CloudLibraryStore()
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
    private var liveCaptionSessionObserver: AnyCancellable?
    private var previousRecorderState: RecorderState = .idle
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenParametersObserver: NSObjectProtocol?
    private var panelTransitionToken: Int = 0
    private var isSyncingPanelVisibility = false
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
    @Published private(set) var isLiveCaptionPanelPresented = false
    @Published private(set) var liveCaptionPanelMode: LiveCaptionPanelMode = .expanded

    private var effectiveActiveAudioBundleIDs: Set<String> {
        Set(recorder.runningApps.lazy.filter(\.isActive).map(\.id))
    }

    private var hiddenAutoPromptSnoozeDuration: TimeInterval {
        uiTestMode.hiddenAutoPromptSnoozeSeconds ?? 6
    }

    private var detectedMeetingAutoStopGraceDuration: TimeInterval {
        uiTestMode.detectedMeetingAutoStopGraceSeconds ?? 8
    }

    private var dismissedLiveCaptionSessionDefaultsKey: String {
        "recappi.cloud.dismissedLiveCaptionSessionID"
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
        // Apply the user's theme before any window is created so the very
        // first surface (status item, floating panel, onboarding) comes up
        // in the correct appearance.
        ThemeManager.shared.startObserving()
        NSApp.setActivationPolicy(.accessory)
        installStatusItemIfNeeded()
        appUpdater.prepareForUserInitiatedCheck = { [weak self] in
            self?.prepareForForegroundUpdateCheck()
        }
        appUpdater.finishUserInitiatedCheck = { [weak self] in
            self?.releaseForegroundWindowDemand()
        }
        Task { @MainActor in
            await AuthSessionStore.shared.bootstrapForUITestsIfNeeded()
            if self.uiTestMode.openCloudWindowOnLaunch {
                self.showCloudCenter()
            }
        }
        appUpdater.start()
        configureNotifications()

        // First-launch onboarding (intro → permissions → sign-in). Skipped
        // on subsequent launches via `OnboardingState.didComplete`. Runs
        // alongside the floating panel install so a returning user does
        // not see any gating behavior. UI-automation env vars
        // (`RECAPPI_TEST_FORCE_ONBOARDING` / `RECAPPI_TEST_SUPPRESS_ONBOARDING`)
        // can override the persisted flag for fixture stability.
        //
        // Implicit suppression for Cloud-window UI smoke runs:
        // `RECAPPI_TEST_OPEN_CLOUD_WINDOW=1` fixtures expect the Cloud
        // window to be the foreground surface on launch. On a CI runner
        // with empty UserDefaults the onboarding window would slot in
        // front and break those tests. We only force-suppress here when
        // the run did *not* explicitly set
        // `RECAPPI_TEST_FORCE_ONBOARDING=1`, so a fixture that wants to
        // test onboarding alongside cloud open can still opt in.
        let implicitOnboardingSuppression =
            uiTestMode.openCloudWindowOnLaunch
            && !uiTestMode.forceOnboardingForTesting
        if OnboardingState.shouldPresentOnLaunch(
            uiTestModeForcesOnboarding: uiTestMode.forceOnboardingForTesting,
            uiTestModeSuppressesOnboarding: uiTestMode.suppressOnboardingForTesting
                || implicitOnboardingSuppression
        ) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showOnboardingWindow()
            }
        }

        if uiTestMode.openCloudWindowOnLaunch {
            return
        }

        let m = PillShellView.shadowMargin
        let pillWidth = DT.panelWidth
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: pillWidth + m * 2, height: 56 + m * 2))

        let contentView = RecordingPanel(
            recorder: recorder,
            onOpenFolder: { folderURL in NSWorkspace.shared.open(folderURL) },
            onOpenCloud: { [weak self] in self?.showCloudCenter() },
            onClosePanel: { [weak self] in self?.hidePanel() },
            onCloudRecordingUpdated: { [weak self] recording, latestJob in
                self?.cloudStore.upsertLocalProcessingRecording(recording, latestJob: latestJob)
            },
            onCloudRecordingDeleted: { [weak self] recordingID in
                self?.cloudStore.removeLocalProcessingRecording(id: recordingID)
            }
        )

        let hostingView = FloatingPanelHostingView(
            rootView: ThemedHost {
                FloatingPanelChromeView {
                    contentView
                }
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
        previousRecorderState = recorder.state
        recorderStateObserver = recorder.$state
            .sink { [weak self] state in
                guard let self else { return }
                let previous = self.previousRecorderState
                self.previousRecorderState = state

                let isRecording = state.isRecording
                if self.isRecording != isRecording {
                    self.isRecording = isRecording
                    self.updateStatusItemRecordingState(isRecording)
                }

                self.notifyHiddenProcessingTransitionIfNeeded(from: previous, to: state)
                self.reconcileLiveCaptionPanelPresentation()
            }

        liveCaptionSessionObserver = recorder.$activeRecordingID
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reconcileLiveCaptionPanelPresentation()
                }
            }
    }

    func applicationWillTerminate(_ notification: Notification) {
        activePromptRefreshTask?.cancel()
        browserAutoPromptTask?.cancel()
        hiddenPanelAutoPromptTask?.cancel()
        detectedMeetingAutoStopTask?.cancel()
        runningAppsRefreshTask?.cancel()
        recorderStateObserver?.cancel()
        liveCaptionSessionObserver?.cancel()
        closeLiveCaptionWindow()
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

        let about = NSMenuItem(
            title: "About Recappi Mini",
            action: #selector(showAboutFromStatusMenu),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

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
        showSettingsWindow()
    }

    @objc private func checkForUpdatesFromStatusMenu() {
        appUpdater.checkForUpdates()
    }

    @objc private func showAboutFromStatusMenu() {
        showAboutPanel()
    }

    @objc private func quitFromStatusMenu() {
        NSApp.terminate(nil)
    }

    func showAboutPanel() {
        if let aboutWindow = managedWindows.aboutWindow {
            activateForegroundWindowPresentation()
            aboutWindow.makeKeyAndOrderFront(nil)
            return
        }

        prepareForForegroundWindowPresentation()

        let hostingView = NSHostingView(
            rootView: ThemedHost {
                AboutRecappiMiniView()
                    .environmentObject(AppUpdater.shared)
            }
        )
        let window = WindowFactory.createWindow(
            contentView: hostingView,
            spec: WindowFactory.WindowSpec(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 292),
                styleMask: [.titled, .closable, .fullSizeContentView],
                title: "About Recappi Mini",
                titleVisibility: .hidden,
                hiddenStandardButtons: [.miniaturizeButton, .zoomButton],
                isMovableByWindowBackground: true,
                contentMinSize: NSSize(width: 460, height: 292),
                contentMaxSize: NSSize(width: 460, height: 292)
            ),
            delegate: self
        )
        window.makeKeyAndOrderFront(nil)
        managedWindows.aboutWindow = window
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
        if recorder.state.isProcessing {
            requestNotificationAuthorizationIfNeeded()
        }
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

    func showSettingsWindow() {
        if let settingsWindow = managedWindows.settingsWindow {
            activateForegroundWindowPresentation()
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        prepareForForegroundWindowPresentation()

        let hostingView = NSHostingView(
            rootView: ThemedHost {
                SettingsView(ownsForegroundWindowDemand: false)
                    .environmentObject(AppConfig.shared)
                    .environmentObject(AuthSessionStore.shared)
                    .environmentObject(AppUpdater.shared)
            }
        )
        let window = WindowFactory.createWindow(
            contentView: hostingView,
            spec: WindowFactory.WindowSpec(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                title: "Recappi Mini Settings",
                contentMinSize: NSSize(width: 720, height: 520)
            ),
            delegate: self
        )
        window.makeKeyAndOrderFront(nil)
        managedWindows.settingsWindow = window
    }

    func showCloudCenter() {
        if let cloudWindow = managedWindows.cloudWindow {
            activateForegroundWindowPresentation()
            cloudWindow.makeKeyAndOrderFront(nil)
            return
        }

        prepareForForegroundWindowPresentation()

        let hostingView = NSHostingView(
            rootView: ThemedHost {
                CloudCenterPanel(store: cloudStore, recorder: recorder)
                    .environmentObject(AppConfig.shared)
                    .environmentObject(AuthSessionStore.shared)
                    .environmentObject(AppDelegate.shared)
            }
        )
        // Standard NSWindow chrome — traffic lights restored, native
        // title visible. NavigationSplitView and `.toolbar` provide the
        // sidebar Liquid Glass material and the title-bar action items;
        // there is no SwiftUI-owned header anymore.
        let window = WindowFactory.createWindow(
            contentView: hostingView,
            spec: WindowFactory.WindowSpec(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                title: "Recappi Cloud",
                contentMinSize: NSSize(width: 880, height: 600)
            ),
            delegate: self
        )
        window.toolbarStyle = .unified
        window.makeKeyAndOrderFront(nil)
        managedWindows.cloudWindow = window
    }

    func setLiveCaptionPanelPresented(_ presented: Bool) {
        guard AppConfig.shared.liveCaptionsDisplayEnabled else {
            hideLiveCaptionWindow()
            return
        }
        guard let sessionID = currentLiveCaptionSessionID else {
            hideLiveCaptionWindow()
            return
        }

        if presented {
            if dismissedLiveCaptionSessionID == sessionID {
                dismissedLiveCaptionSessionID = ""
            }
            presentLiveCaptionWindow()
        } else {
            dismissLiveCaptionWindow(for: sessionID)
        }
    }

    var canShowLiveCaptionPanel: Bool {
        AppConfig.shared.liveCaptionsDisplayEnabled && currentLiveCaptionSessionID != nil
    }

    func toggleLiveCaptionPanelMode() {
        switch liveCaptionPanelMode {
        case .expanded:
            liveCaptionPanelMode = .compact
        case .compact:
            liveCaptionPanelMode = .expanded
        }
        resizeLiveCaptionWindowToContent()
    }

    func applyLiveCaptionDisplayPreference() {
        reconcileLiveCaptionPanelPresentation()
    }

    private var isCurrentMeetingActiveForCaptions: Bool {
        switch recorder.state {
        case .starting, .recording:
            true
        default:
            false
        }
    }

    private var currentLiveCaptionSessionID: String? {
        guard isCurrentMeetingActiveForCaptions else { return nil }
        return recorder.activeRecordingID?.uuidString ?? recorder.currentSessionDir?.path
    }

    private var dismissedLiveCaptionSessionID: String {
        get { UserDefaults.standard.string(forKey: dismissedLiveCaptionSessionDefaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: dismissedLiveCaptionSessionDefaultsKey) }
    }

    private func reconcileLiveCaptionPanelPresentation() {
        guard AppConfig.shared.liveCaptionsDisplayEnabled else {
            hideLiveCaptionWindow()
            return
        }
        guard let sessionID = currentLiveCaptionSessionID else {
            hideLiveCaptionWindow()
            return
        }

        if dismissedLiveCaptionSessionID == sessionID {
            hideLiveCaptionWindow()
        } else {
            presentLiveCaptionWindow()
        }
    }

    private func presentLiveCaptionWindow() {
        if let liveCaptionWindow = managedWindows.liveCaptionWindow {
            positionLiveCaptionWindow(liveCaptionWindow)
            liveCaptionWindow.orderFrontRegardless()
            isLiveCaptionPanelPresented = true
            return
        }

        let hostingView = LiveCaptionPassthroughHostingView(rootView: liveCaptionRootView())
        // Empty sizingOptions makes NSHostingView track the NSWindow's
        // content bounds (including user resizes) rather than pin to
        // SwiftUI's intrinsic size. `GeometryReader` inside
        // `LiveCaptionFloatingPanel` then reads that real height.
        hostingView.sizingOptions = []

        // `.titled` + `.resizable` (without `.fullSizeContentView`) is
        // what gives us standard NSWindow edge-drag resize handles —
        // a pure `.borderless` panel does not honor `.resizable` on
        // macOS. The title chrome is hidden below so visually it still
        // reads as a floating panel.
        let window = WindowFactory.createPanel(
            contentView: hostingView,
            spec: WindowFactory.PanelSpec(
                contentRect: NSRect(origin: .zero, size: liveCaptionPanelMode.defaultWindowSize),
                styleMask: [.nonactivatingPanel, .titled, .resizable],
                title: "Recappi Live Captions",
                hasShadow: true,
                titleVisibility: .hidden,
                titlebarAppearsTransparent: true,
                hiddenStandardButtons: [.closeButton, .miniaturizeButton, .zoomButton]
            ),
            delegate: self
        )

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        window.setContentSize(NSSize(
            width: max(liveCaptionPanelMode.defaultWindowSize.width, fittingSize.width),
            height: max(liveCaptionPanelMode.defaultWindowSize.height, fittingSize.height)
        ))
        applyLiveCaptionContentSizeConstraints(window, mode: liveCaptionPanelMode)
        positionLiveCaptionWindow(window)
        window.orderFrontRegardless()

        managedWindows.liveCaptionWindow = window
        isLiveCaptionPanelPresented = true
    }

    /// Width/height floor + ceiling for the live caption NSPanel.
    /// Expanded reserves space for the header + a usable viewport;
    /// compact pins to its nominal default so the two-line caption +
    /// control cluster cannot be squashed.
    private func applyLiveCaptionContentSizeConstraints(_ window: NSWindow, mode: LiveCaptionPanelMode) {
        switch mode {
        case .expanded:
            window.contentMinSize = NSSize(width: 560, height: 280)
            window.contentMaxSize = NSSize(width: 900, height: 1200)
        case .compact:
            window.contentMinSize = mode.defaultWindowSize
            window.contentMaxSize = NSSize(width: 900, height: mode.defaultWindowSize.height)
        }
    }

    private func hideLiveCaptionWindow() {
        // Hide keeps the warm panel instance around. The panel hosts live ASR
        // text and mode state, so transient app-state changes should not close
        // and recreate it unless we are truly tearing the app/window down.
        managedWindows.liveCaptionWindow?.orderOut(nil)
        isLiveCaptionPanelPresented = false
    }

    private func dismissLiveCaptionWindow(for sessionID: String) {
        dismissedLiveCaptionSessionID = sessionID
        hideLiveCaptionWindow()
    }

    private func closeLiveCaptionWindow() {
        guard let window = managedWindows.liveCaptionWindow else {
            isLiveCaptionPanelPresented = false
            return
        }
        managedWindows.clear(.liveCaptions)
        isLiveCaptionPanelPresented = false
        window.delegate = nil
        window.close()
    }

    private func resizeLiveCaptionWindowToContent() {
        guard let liveCaptionWindow = managedWindows.liveCaptionWindow,
              let hostingView = liveCaptionWindow.contentView as? LiveCaptionPassthroughHostingView<AnyView> else {
            managedWindows.liveCaptionWindow?.setContentSize(liveCaptionPanelMode.defaultWindowSize)
            if let liveCaptionWindow = managedWindows.liveCaptionWindow {
                positionLiveCaptionWindow(liveCaptionWindow)
            }
            return
        }

        hostingView.rootView = liveCaptionRootView()
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize

        // Capture the visual bottom edge BEFORE resizing. NSWindow
        // origin is bottom-left, so `frame.origin.y` is the bottom edge
        // in Cocoa screen coords. `setContentSize` would otherwise
        // re-anchor at the top-left, but the user parks this panel near
        // the dock and expects the bottom edge to stay put while the
        // top edge slides up/down on mode toggle.
        let previousBottomY = liveCaptionWindow.frame.origin.y
        applyLiveCaptionContentSizeConstraints(liveCaptionWindow, mode: liveCaptionPanelMode)
        liveCaptionWindow.setContentSize(NSSize(
            width: max(liveCaptionPanelMode.defaultWindowSize.width, fittingSize.width),
            height: max(liveCaptionPanelMode.defaultWindowSize.height, fittingSize.height)
        ))
        var anchoredFrame = liveCaptionWindow.frame
        anchoredFrame.origin.y = previousBottomY
        liveCaptionWindow.setFrame(anchoredFrame, display: true)
    }

    private func liveCaptionRootView() -> AnyView {
        // No `windowPadding`: pinning the SwiftUI tree flush to the
        // NSWindow frame keeps the visible rounded edge aligned with
        // the AppKit resize hit-zone. NSWindow draws its own shadow
        // outside the frame (via `panel.hasShadow = true`).
        AnyView(
            ThemedHost {
                LiveCaptionFloatingPanel(
                    recorder: recorder,
                    mode: liveCaptionPanelMode,
                    onToggleMode: { [weak self] in
                        self?.toggleLiveCaptionPanelMode()
                    },
                    onClose: { [weak self] in
                        self?.setLiveCaptionPanelPresented(false)
                    }
                )
                .environmentObject(AppConfig.shared)
            }
        )
    }

    private func positionLiveCaptionWindow(_ window: NSWindow) {
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var frame = window.frame
        frame.origin.x = visibleFrame.maxX - frame.width - 24
        frame.origin.y = visibleFrame.minY + 24
        window.setFrame(frame, display: true)
    }

    /// Present the first-launch onboarding modal. Called by
    /// `finishLaunchingIfNeeded` when `OnboardingState.shouldPresentOnLaunch`
    /// is true. The window is its own NSWindow rather than a sheet so the
    /// user can move it, see the menu bar status item appearing in the
    /// background, and get a clear "complete this once" affordance.
    func showOnboardingWindow() {
        if let existing = managedWindows.onboardingWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Promote the app to a regular activation policy while the window is
        // visible so it can become key (the floating panel uses
        // `.accessory`, which would prevent that). We restore on close.
        prepareForForegroundWindowPresentation()

        let view = OnboardingView(sessionStore: AuthSessionStore.shared) { [weak self] in
            self?.completeOnboardingAndDismiss()
        }
        let hostingView = NSHostingView(rootView: ThemedHost { view })
        let window = WindowFactory.createWindow(
            contentView: hostingView,
            spec: WindowFactory.WindowSpec(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
                styleMask: [.titled, .closable, .fullSizeContentView],
                title: "Welcome to Recappi",
                titleVisibility: .hidden,
                isMovableByWindowBackground: true
            ),
            delegate: self
        )
        window.makeKeyAndOrderFront(nil)
        managedWindows.onboardingWindow = window
    }

    /// Called when the onboarding view's `onFinish` fires (Done / Get
    /// started). Persist completion, drop the window, and fall back to the
    /// standard accessory activation policy if no other foreground window
    /// is open.
    private func completeOnboardingAndDismiss() {
        OnboardingState.didComplete = true
        if let window = managedWindows.onboardingWindow {
            window.delegate = nil
            window.close()
            managedWindows.clear(.onboarding)
        }
        releaseForegroundWindowDemand()
    }

    func prepareForForegroundWindowPresentation() {
        foregroundWindows.preparePresentation()
    }

    func prepareForSettingsScenePresentation() {
        foregroundWindows.prepareSettingsScenePresentation()
    }

    func releaseSettingsSceneForegroundDemand() {
        foregroundWindows.releaseSettingsSceneDemand()
    }

    private func activateForegroundWindowPresentation() {
        foregroundWindows.activatePresentation()
    }

    private func prepareForForegroundUpdateCheck() {
        prepareForForegroundWindowPresentation()
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
        if let liveCaptionWindow = managedWindows.liveCaptionWindow, liveCaptionWindow.isVisible {
            positionLiveCaptionWindow(liveCaptionWindow)
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
        guard !isSyncingPanelVisibility else { return }
        guard let panel else {
            panelVisible = false
            return
        }
        guard !panel.isFloatingTransitioning else { return }

        isSyncingPanelVisibility = true
        defer { isSyncingPanelVisibility = false }

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

    func releaseForegroundWindowDemand() {
        foregroundWindows.releaseDemand()
    }

    private func restoreAccessoryActivationPolicyIfPossible() {
        foregroundWindows.restoreAccessoryPolicyIfPossible()
    }

    private func configureNotifications() {
        UNUserNotificationCenter.current().delegate = self
    }

    private func requestNotificationAuthorizationIfNeeded(_ completion: (@Sendable (Bool) -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                completion?(true)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    completion?(granted)
                }
            default:
                completion?(false)
            }
        }
    }

    private func notifyHiddenProcessingTransitionIfNeeded(from previous: RecorderState, to current: RecorderState) {
        guard previous.isProcessing, panelTargetVisible == false else { return }

        switch current {
        case .done(let result):
            let transcript = (result.transcript ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            let body = transcript.isEmpty
                ? "Your recording has been transcribed."
                : String(transcript.prefix(140))
            postProcessingNotification(
                title: "Transcription complete",
                body: body,
                playSound: false
            )
        case .error(let message):
            postProcessingNotification(
                title: "Processing failed",
                body: message,
                playSound: true
            )
        default:
            return
        }
    }

    private func postProcessingNotification(title: String, body: String, playSound: Bool) {
        requestNotificationAuthorizationIfNeeded { granted in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.threadIdentifier = "recappi.processing"
            content.userInfo = ["action": "showPanel"]
            if playSound {
                content.sound = .default
            }

            let request = UNNotificationRequest(
                identifier: "recappi.processing.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
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
        guard let closingWindow = notification.object as? NSWindow else { return }
        guard let route = managedWindowCloseRoute(for: closingWindow) else { return }
        handleManagedWindowClose(route)
    }

    private func managedWindowCloseRoute(for window: NSWindow) -> ManagedWindowRegistry.Route? {
        managedWindows.route(for: window)
    }

    private func handleManagedWindowClose(_ route: ManagedWindowRegistry.Route) {
        managedWindows.clear(route)
        switch route {
        case .settings:
            releaseForegroundWindowDemand()
        case .cloud:
            releaseForegroundWindowDemand()
        case .liveCaptions:
            isLiveCaptionPanelPresented = false
            restoreAccessoryActivationPolicyIfPossible()
        case .onboarding:
            // The native title-bar close button is the onboarding escape
            // hatch. It replaces the old in-view footer Skip button, so
            // closing the window marks first-launch onboarding complete
            // and prevents it from popping back on the next launch.
            OnboardingState.lastStep = .done
            OnboardingState.didComplete = true
            releaseForegroundWindowDemand()
        case .about:
            releaseForegroundWindowDemand()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            AppDelegate.shared.showPanel(activateApp: true)
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Drops mouse hits on the four rounded-corner gaps outside the
/// visible panel surface so clicks pass through to whatever's behind.
/// The corners are computed geometrically — `super.hitTest` returns
/// `self` for any point in bounds, so a "result === self → nil" check
/// would also swallow legitimate SwiftUI button taps.
final class LiveCaptionPassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// Outer bound of the visible rounded surface. The SwiftUI tree
    /// paints 16pt expanded / 14pt compact; 16pt is the conservative
    /// outer bound — anything inside the larger inset is opaque in
    /// both modes.
    private let cornerRadius: CGFloat = 16

    override func hitTest(_ point: NSPoint) -> NSView? {
        let bounds = self.bounds
        // Reject only points outside the rounded rect (the four corner
        // gaps where the surface is fully transparent). Everywhere
        // inside is visible chrome and must keep receiving events.
        let dx = max(bounds.minX + cornerRadius - point.x, point.x - (bounds.maxX - cornerRadius), 0)
        let dy = max(bounds.minY + cornerRadius - point.y, point.y - (bounds.maxY - cornerRadius), 0)
        if dx > 0 && dy > 0 && (dx * dx + dy * dy) > cornerRadius * cornerRadius {
            return nil
        }
        return super.hitTest(point)
    }
}
