import AppKit
import AVFoundation
import Combine
import SwiftUI
@preconcurrency import UserNotifications

@main
struct RecappiMiniApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegateProxy.self) private var appLifecycleDelegate

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
        // Use the native Settings scene so macOS renders preference-style
        // icon tabs in the toolbar instead of our fallback hosted window.
        Settings {
            settingsRoot
        }
        .windowResizability(.contentSize)
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
final class AppLifecycleDelegateProxy: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared.applicationDidFinishLaunching(notification)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppDelegate.shared.applicationDidBecomeActive(notification)
    }

    func applicationDidResignActive(_ notification: Notification) {
        AppDelegate.shared.applicationDidResignActive(notification)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDelegate.shared.applicationShouldTerminate(sender)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.shared.applicationWillTerminate(notification)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, NSWindowDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    static let shared = AppDelegate()

    private enum RecordingQuitConfirmation {
        case keepRecording
        case stopAndQuit
    }

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
        let browserSessionKey: String?
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
    /// Backdrop-adaptive chrome (#185). One observer is shared by the
    /// floating panel's SwiftUI chrome; attached after `panel.orderFront`
    /// so it has a real NSWindow to sample around.
    private let backdropLuminance = BackdropLuminanceObserver()
    private var openSettingsAction: (() -> Void)?
    private let uiTestMode = UITestModeConfiguration.shared
    private var activityObserver: AnyCancellable?
    private var promptedAutoPromptKeyByBundleID: [String: String] = [:]
    private var autoPromptSuppressedUntilInactiveBundleIDs: Set<String> = []
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
    private var isStoppingRecordingForTermination = false
    private var pendingTerminationStopTask: Task<Void, Never>?
    private var uiTestMeetingLabelByBundleID: [String: String] = [:]
    private var panelTargetVisible = true {
        didSet {
            panelVisible = panelTargetVisible
            recorder.setRecordingMeterVisible(panelTargetVisible)
        }
    }

    /// Tracks whether the user wants the floating panel shown so tray menus
    /// don't mistake a warm offscreen panel for an interactive one.
    @Published var panelVisible: Bool = true
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isLiveCaptionPanelPresented = false
    @Published private(set) var liveCaptionPanelMode: LiveCaptionPanelMode = .expanded
    private var liveCaptionChromeVisible = false

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

    func applicationDidBecomeActive(_ notification: Notification) {
        DiagnosticsLog.event("app", "lifecycle.active")
    }

    func applicationDidResignActive(_ notification: Notification) {
        DiagnosticsLog.event("app", "lifecycle.inactive")
    }

    func finishLaunchingIfNeeded() {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        SentryReporter.start()
        DiagnosticsLog.installCrashHandlers()
        DiagnosticsLog.event("sentry", "sdk.enabled=\(SentryReporter.isEnabledForCurrentProcess)")
        if let session = AuthSessionStore.shared.currentSession {
            SentryReporter.setUserIdentity(session)
        } else {
            SentryReporter.clearUserIdentity()
        }
        logAppLaunch()
        // Apply the user's theme before any window is created so the very
        // first surface (status item, floating panel, onboarding) comes up
        // in the correct appearance.
        ThemeManager.shared.startObserving()
        NSApp.setActivationPolicy(.accessory)
        if uiTestMode.stateBoardVisualFixtureEnabled {
            UserDefaults.standard.set(true, forKey: "recordingIncludeMicrophoneAudio")
            AppConfig.shared.recordingIncludeMicrophoneAudio = true
            AppConfig.shared.recordingAutoTranscribeAfterUpload = true
            UserDefaults.standard.set("spectrum", forKey: "recappi.panel.recordingWaveformMode")
            installStateBoardCloudFixture()
        }
        installStatusItemIfNeeded()
        appUpdater.prepareForUserInitiatedCheck = { [weak self] in
            self?.prepareForForegroundUpdateCheck()
        }
        appUpdater.finishUserInitiatedCheck = { [weak self] in
            self?.releaseForegroundWindowDemand()
        }
        Task { @MainActor in
            await AuthSessionStore.shared.bootstrapForUITestsIfNeeded()
            if self.uiTestMode.openSettingsWindowOnLaunch {
                try? await Task.sleep(nanoseconds: 250_000_000)
                self.showSettingsWindow()
            }
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
            onOpenCloudRecording: { [weak self] recordingID in
                self?.showCloudCenter(selectingRecordingID: recordingID)
            },
            onClosePanel: { [weak self] in self?.hidePanel() },
            onTranscribeCloudRecording: { [weak self] recordingID, onJobUpdate in
                guard let self else { return }
                self.showCloudCenter(selectingRecordingID: recordingID)
                Task { @MainActor [weak self] in
                    await self?.cloudStore.processRecording(
                        id: recordingID,
                        .transcriptAndSummary,
                        onJobUpdate: onJobUpdate
                    )
                }
            },
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
        // Bind the backdrop observer to the host's NSAppearance so all
        // appearance-aware tokens flip together (#185). See the comment
        // on `FloatingPanelHostingView.luminanceObserver`.
        hostingView.luminanceObserver = backdropLuminance

        // AppKit only measures and hosts; SwiftUI owns the rounded chrome,
        // shadow, and show/hide motion so panel transitions stay compositor-friendly.
        let shell = PillShellView(frame: NSRect(x: 0, y: 0, width: 280 + m * 2, height: 56 + m * 2))
        shell.setContent(hostingView)
        panel.contentView = shell
        panel.delegate = self
        FloatingPanelController.positionAtTopRight(panel, width: pillWidth, height: 56)
        panel.orderFrontRegardless()
        backdropLuminance.attach(to: panel)

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
                    self.recorder.setRecordingMeterVisible(self.panelTargetVisible && isRecording)
                }

                self.notifyHiddenProcessingTransitionIfNeeded(from: previous, to: state)
                self.handleDetectedMeetingRecordingActivity(self.effectiveActiveAudioBundleIDs)
                self.reconcileLiveCaptionPanelPresentation()
            }

        liveCaptionSessionObserver = recorder.$activeRecordingID
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reconcileLiveCaptionPanelPresentation()
                }
            }

        installStateBoardRecordingPanelFixtureIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !uiTestMode.isEnabled else { return .terminateNow }
        guard recorder.state.requiresQuitConfirmation else { return .terminateNow }
        guard !isStoppingRecordingForTermination else { return .terminateLater }

        DiagnosticsLog.event("app", "terminate.request while_recording state=\(recorder.state)")
        switch presentRecordingQuitConfirmationAlert() {
        case .keepRecording:
            DiagnosticsLog.event("app", "terminate.cancelled reason=recording_active")
            showPanel(activateApp: true)
            return .terminateCancel
        case .stopAndQuit:
            beginStoppingRecordingForTermination(sender)
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticsLog.event("app", "lifecycle.terminate")
        pendingTerminationStopTask?.cancel()
        pendingTerminationStopTask = nil
        backdropLuminance.detach()
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

    private func presentRecordingQuitConfirmationAlert() -> RecordingQuitConfirmation {
        prepareForForegroundWindowPresentation()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recording in progress"
        alert.informativeText = "Stop the current recording before quitting Recappi Mini, or keep recording and return to the panel."
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Stop Recording and Quit")
        alert.buttons.first?.keyEquivalent = "\r"
        if alert.buttons.indices.contains(1) {
            alert.buttons[1].keyEquivalent = ""
            if #available(macOS 11.0, *) {
                alert.buttons[1].hasDestructiveAction = true
            }
        }

        SentryReporter.pauseAppHangTrackingForExpectedModal(reason: "recording_quit_confirmation")
        let response = alert.runModal()
        SentryReporter.resumeAppHangTrackingForExpectedModal(reason: "recording_quit_confirmation")
        return response == .alertSecondButtonReturn ? .stopAndQuit : .keepRecording
    }

    private func beginStoppingRecordingForTermination(_ sender: NSApplication) {
        isStoppingRecordingForTermination = true
        DiagnosticsLog.event("app", "terminate.stop_recording.begin")
        pendingTerminationStopTask = Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            do {
                let sessionDir = try await self.recorder.stopRecording()
                DiagnosticsLog.event("app", "terminate.stop_recording.saved dir=\(sessionDir.lastPathComponent)")
                self.pendingTerminationStopTask = nil
                sender?.reply(toApplicationShouldTerminate: true)
            } catch {
                DiagnosticsLog.error("app", "terminate.stop_recording.failed \(DiagnosticsLog.errorSummary(error))")
                self.isStoppingRecordingForTermination = false
                self.pendingTerminationStopTask = nil
                self.recorder.state = .error(message: NetworkErrorPresenter.userFacingMessage(for: error))
                self.showPanel(activateApp: true)
                sender?.reply(toApplicationShouldTerminate: false)
            }
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.masksToBounds = false
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
        updateStatusItemRecordingChrome(isRecording)
        positionRecordingDot()
        DispatchQueue.main.async { [weak self] in
            self?.positionRecordingDot()
        }
        recordingDotView?.isHidden = !isRecording
        if isRecording {
            startRecordingDotPulse()
        } else {
            stopRecordingDotPulse()
        }
    }

    private func updateStatusItemRecordingChrome(_ isRecording: Bool) {
        guard let statusItem, let button = statusItem.button else { return }

        statusItem.length = isRecording ? 30 : NSStatusItem.squareLength
        button.wantsLayer = true
        button.needsLayout = true
        button.layoutSubtreeIfNeeded()
        button.layer?.cornerRadius = isRecording ? 9 : 6
        button.layer?.cornerCurve = .continuous
        button.layer?.masksToBounds = false

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        button.layer?.backgroundColor = isRecording
            ? NSColor.systemRed.withAlphaComponent(0.38).cgColor
            : NSColor.clear.cgColor
        button.layer?.borderColor = isRecording
            ? NSColor.systemRed.withAlphaComponent(0.62).cgColor
            : NSColor.clear.cgColor
        button.layer?.borderWidth = isRecording ? 0.8 : 0
        CATransaction.commit()
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

    private func logAppLaunch() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let process = ProcessInfo.processInfo
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let screenCaptureAccess = CapturePermissionPrimer.shared.hasScreenCaptureAccess()
        DiagnosticsLog.event(
            "app",
            "launch version=\(version) build=\(build) pid=\(process.processIdentifier) os='\(DiagnosticsLog.sanitize(process.operatingSystemVersionString, maxLength: 80))' arch=\(Self.processArchitecture) uiTest=\(uiTestMode.isEnabled) micStatus=\(micStatus.rawValue) screenCapture=\(screenCaptureAccess) lowPower=\(process.isLowPowerModeEnabled) appearance=\(Self.effectiveAppearanceName) locale=\(Locale.current.identifier) diskFreeMb=\(Self.availableDiskMegabytes ?? -1) logs=\(DiagnosticsLog.fileURL.path)"
        )
    }

    private static var effectiveAppearanceName: String {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
    }

    private static var availableDiskMegabytes: Int? {
        let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int(bytes / 1_048_576)
    }

    private static var processArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    @objc private func togglePanelFromStatusMenu() {
        togglePanel()
        updateStatusMenuItems()
    }

    @objc private func openLogsFolderFromStatusMenu() {
        DiagnosticsLog.event("diagnostics", "open_logs_folder source=status_menu")
        NSWorkspace.shared.open(DiagnosticsLog.logsDirectoryURL)
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
        prepareForSettingsScenePresentation()

        if let openSettingsAction {
            openSettingsAction()
            return
        }

        if openNativeSettingsScene() {
            Task { @MainActor in
                // The native Settings command can be registered a tick after
                // app launch; resend once so UI-test startup lands on the
                // preference-style scene instead of the hosted fallback.
                try? await Task.sleep(nanoseconds: 250_000_000)
                _ = self.openNativeSettingsScene()
            }
            return
        }

        if let settingsWindow = managedWindows.settingsWindow {
            activateForegroundWindowPresentation()
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let hostingView = NSHostingView(
            rootView: ThemedHost {
                SettingsView(ownsForegroundWindowDemand: false)
                    .environmentObject(AppConfig.shared)
                    .environmentObject(AuthSessionStore.shared)
                    .environmentObject(AppUpdater.shared)
            }
        )
        hostingView.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
        let initialContentSize = NSSize(
            width: settingsWindowContentWidth,
            height: SettingsItem.general.fallbackContentHeight
        )
        let window = WindowFactory.createWindow(
            contentView: hostingView,
            spec: WindowFactory.WindowSpec(
                contentRect: NSRect(origin: .zero, size: initialContentSize),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                title: "Recappi Mini Settings",
                titlebarAppearsTransparent: false,
                contentMinSize: initialContentSize,
                contentMaxSize: initialContentSize
            ),
            delegate: self
        )
        window.toolbarStyle = .preference
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.makeKeyAndOrderFront(nil)
        managedWindows.settingsWindow = window
    }

    func registerOpenSettingsAction(_ action: @escaping () -> Void) {
        openSettingsAction = action
    }

    @discardableResult
    private func openNativeSettingsScene() -> Bool {
        for selectorName in ["showSettingsWindow:", "showPreferencesWindow:", "showSettings:"] {
            if NSApp.sendAction(Selector(selectorName), to: nil, from: nil) {
                return true
            }
        }
        return false
    }

    func showCloudCenter(selectingRecordingID recordingID: String? = nil) {
        if let recordingID {
            _ = cloudStore.selectRecording(id: recordingID)
        }
        DiagnosticsLog.event("cloud", "window.open recordingID=\(recordingID ?? "none")")
        if let cloudWindow = managedWindows.cloudWindow {
            activateForegroundWindowPresentation()
            cloudWindow.makeKeyAndOrderFront(nil)
            if let recordingID {
                _ = cloudStore.selectRecording(id: recordingID)
            }
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
                title: "Cloud",
                contentMinSize: NSSize(width: 880, height: 600)
            ),
            delegate: self
        )
        window.toolbarStyle = .unified
        window.makeKeyAndOrderFront(nil)
        managedWindows.cloudWindow = window
    }

    private func installStateBoardCloudFixture() {
        let created = Date().addingTimeInterval(-3_600)
        let recording = CloudRecording(
            id: "state-board-weekly-sync",
            userId: "state-board-user",
            title: "Weekly engineering sync",
            summaryTitle: "Weekly engineering sync",
            sourceTitle: "Google Meet",
            sourceAppName: "Google Chrome",
            sourceAppBundleID: "com.google.Chrome",
            r2Key: nil,
            r2UploadId: nil,
            status: .ready,
            sizeBytes: 8_600_000,
            durationMs: 1_840_000,
            sampleRate: 48_000,
            channels: 2,
            contentType: "audio/mpeg",
            activeTranscriptId: "state-board-transcript",
            createdAt: created,
            updatedAt: created.addingTimeInterval(120)
        )
        let later = CloudRecording(
            id: "state-board-design-review",
            userId: "state-board-user",
            title: "Design review with platform team",
            summaryTitle: "Design review with platform team",
            sourceTitle: "Zoom",
            sourceAppName: "Zoom",
            sourceAppBundleID: "us.zoom.xos",
            r2Key: nil,
            r2UploadId: nil,
            status: .ready,
            sizeBytes: 5_200_000,
            durationMs: 1_120_000,
            sampleRate: 48_000,
            channels: 2,
            contentType: "audio/mpeg",
            activeTranscriptId: "state-board-transcript-2",
            createdAt: created.addingTimeInterval(-86_400),
            updatedAt: created.addingTimeInterval(-85_800)
        )
        cloudStore.recordings = [recording, later]
        cloudStore.selectedRecordingID = recording.id
        cloudStore.totalRecordingCount = 2
        cloudStore.lastSuccessfulRefreshAt = Date()
        cloudStore.state = .loaded
        cloudStore.transcriptCache[recording.id] = Self.stateBoardTranscriptFixture()
        cloudStore.transcriptCacheRecordingUpdatedAt[recording.id] = recording.updatedAt
        cloudStore.transcriptionJobsByRecordingID[recording.id] = [
            TranscriptionJob(
                id: "state-board-job",
                status: .succeeded,
                transcriptId: recording.activeTranscriptId,
                provider: "Recappi Cloud",
                model: "gpt-4o-transcribe",
                language: "en-US",
                prompt: nil,
                error: nil,
                attempts: 1,
                enqueuedAt: nil,
                startedAt: nil,
                finishedAt: nil
            )
        ]
    }

    private func installStateBoardRecordingPanelFixtureIfNeeded() {
        guard uiTestMode.stateBoardVisualFixtureEnabled,
              let state = uiTestMode.stateBoardRecordingPanelState?.lowercased(),
              !state.isEmpty else {
            return
        }

        switch state {
        case "idle":
            recorder.state = .idle

        case "recording":
            recorder.state = .recording
            recorder.elapsedSeconds = 47

        case "processing":
            recorder.state = .processing(.polling(jobStatus: "summarizing"))

        case "done-transcribe-pending", "done_transcribe_pending":
            AppConfig.shared.recordingAutoTranscribeAfterUpload = false
            recorder.state = .done(result: stateBoardRecordingResult(transcript: nil, duration: 74))

        case "done-ready", "done_ready", "done-transcript", "done_transcript":
            AppConfig.shared.recordingAutoTranscribeAfterUpload = true
            recorder.state = .done(result: stateBoardRecordingResult(
                transcript: "Ava: Keep the saved receipt focused on one Cloud action.\nBen: Make dismiss quiet and let the next flow feel calm.",
                duration: 193
            ))

        case "error":
            let sessionDir = stateBoardSessionDirectory(name: "state-board-error")
            recorder.lastSessionDir = sessionDir
            recorder.state = .error(message: "Cloud session expired. Sign in again, then retry processing.")

        default:
            break
        }
    }

    private func stateBoardRecordingResult(transcript: String?, duration: Int) -> RecordingResult {
        let sessionDir = stateBoardSessionDirectory(name: "state-board-\(UUID().uuidString)")
        var manifest = RemoteSessionManifest.stage("synced")
        manifest.recordingId = "state-board-recording-\(sessionDir.lastPathComponent)"
        _ = RecordingStore.saveRemoteManifest(manifest, in: sessionDir)
        if let transcript {
            try? RecordingStore.saveTranscript(transcript, in: sessionDir)
        }
        recorder.lastSessionDir = sessionDir
        return RecordingResult(folderURL: sessionDir, transcript: transcript, duration: duration)
    }

    private func stateBoardSessionDirectory(name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recappi-state-board", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func stateBoardTranscriptFixture() -> TranscriptResponse? {
        let raw = """
        {
          "id": "state-board-transcript",
          "text": "Ava opened by framing the onboarding funnel. Ben noted that live captions need clearer status feedback. Chloe proposed simplifying the saved receipt so the primary action is obvious.",
          "summaryStatus": "succeeded",
          "summaryInsights": {
            "title": "Weekly engineering sync",
            "tldr": "The team aligned on a calmer recording receipt, clearer live-caption feedback, and a smaller follow-up list for the next release.",
            "keyPoints": [
              "Keep the saved receipt focused on one primary Cloud action.",
              "Show live caption connection state without interrupting the recording flow.",
              "Use the current UI board to compare spacing, hierarchy, and state coverage before redesigning."
            ],
            "decisions": [
              "Ship the two-line saved receipt framework.",
              "Capture current product states before opening a broader redesign."
            ],
            "actionItems": [
              { "who": "Ava", "what": "Prepare the Pencil review board." },
              { "who": "Ben", "what": "Audit live caption error and reconnect states." }
            ],
            "timeline": [
              { "startMs": 0, "endMs": 420000, "title": "Receipt hierarchy", "summary": "The group compared the saved-state actions and agreed the Cloud link should be the only prominent CTA." },
              { "startMs": 420000, "endMs": 980000, "title": "Live caption feedback", "summary": "The team reviewed caption states and called out missing reconnect and bilingual screenshots for the design board." },
              { "startMs": 980000, "endMs": 1840000, "title": "Design board plan", "summary": "Everyone agreed to collect reproducible state screenshots before committing to a new visual direction." }
            ]
          },
          "segments": [
            { "startMs": 0, "endMs": 180000, "speaker": "Ava", "text": "Let's start with the capture flow and make sure the receipt only has one obvious primary action." },
            { "startMs": 180000, "endMs": 420000, "speaker": "Ben", "text": "The cloud link should be primary, while dismiss can stay quiet and low-contrast." },
            { "startMs": 420000, "endMs": 760000, "speaker": "Chloe", "text": "Live captions still need visible reconnect and bilingual states in the board." },
            { "startMs": 760000, "endMs": 1200000, "speaker": "Ava", "text": "Before redesigning, let's lay out the current app surfaces side by side and mark the confusing parts." },
            { "startMs": 1200000, "endMs": 1840000, "speaker": "Ben", "text": "After that, we can tune hierarchy and spacing with Pencil instead of guessing from one screenshot." }
          ]
        }
        """
        return try? JSONDecoder().decode(TranscriptResponse.self, from: Data(raw.utf8))
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
        setLiveCaptionChromeVisible(false)
        DispatchQueue.main.async { [weak self] in
            self?.resizeLiveCaptionWindowToContent(animated: false, usesFittingSize: false)
        }
    }

    func setLiveCaptionChromeVisible(_ visible: Bool) {
        guard liveCaptionChromeVisible != visible else {
            return
        }
        let previousChromeVisible = liveCaptionChromeVisible
        liveCaptionChromeVisible = visible
        guard liveCaptionPanelMode == .expanded,
              managedWindows.liveCaptionWindow != nil else {
            return
        }
        resizeLiveCaptionWindowForChromeVisibility(previousChromeVisible: previousChromeVisible)
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
            resizeLiveCaptionWindowToContent(animated: false, usesFittingSize: false)
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

        // `.titled` + `.resizable` gives standard NSWindow edge-drag resize
        // handles; `.fullSizeContentView` keeps the SwiftUI header controls in
        // the draggable titlebar band when that band is visible.
        let window = WindowFactory.createPanel(
            contentView: hostingView,
            spec: WindowFactory.PanelSpec(
                contentRect: NSRect(origin: .zero, size: liveCaptionDefaultContentSize()),
                styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                title: "Recappi Live Captions",
                hasShadow: true,
                titleVisibility: .hidden,
                titlebarAppearsTransparent: true,
                hiddenStandardButtons: [.closeButton, .miniaturizeButton, .zoomButton]
            ),
            delegate: self
        )

        window.becomesKeyOnlyIfNeeded = true
        hostingView.refusesFirstResponder = true

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let defaultContentSize = liveCaptionDefaultContentSize()
        window.setContentSize(NSSize(
            width: max(defaultContentSize.width, fittingSize.width),
            height: max(defaultContentSize.height, fittingSize.height)
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
        let defaultContentSize = liveCaptionDefaultContentSize(mode: mode)
        switch mode {
        case .expanded:
            window.contentMinSize = defaultContentSize
            window.contentMaxSize = liveCaptionMaxContentSize(mode: mode)
        case .compact:
            window.contentMinSize = defaultContentSize
            window.contentMaxSize = liveCaptionMaxContentSize(mode: mode)
        }
    }

    private func liveCaptionResizeFrameSize(_ window: NSWindow, requestedFrameSize: NSSize) -> NSSize {
        let requestedFrameRect = NSRect(origin: .zero, size: requestedFrameSize)
        var requestedContentRect = window.contentRect(forFrameRect: requestedFrameRect)
        let minContentSize = liveCaptionDefaultContentSize()
        let maxContentSize = liveCaptionMaxContentSize()

        requestedContentRect.size.width = min(
            max(requestedContentRect.size.width, minContentSize.width),
            maxContentSize.width
        )
        requestedContentRect.size.height = min(
            max(requestedContentRect.size.height, minContentSize.height),
            maxContentSize.height
        )
        return window.frameRect(forContentRect: requestedContentRect).size
    }

    private func liveCaptionDefaultContentSize(
        mode: LiveCaptionPanelMode? = nil,
        chromeVisible: Bool? = nil
    ) -> NSSize {
        let mode = mode ?? liveCaptionPanelMode
        let chromeVisible = chromeVisible ?? liveCaptionChromeVisible
        var size = mode.defaultWindowSize
        if mode == .expanded, !chromeVisible {
            size.height -= LiveCaptionFloatingPanel.expandedHeaderBandHeight
        }
        return size
    }

    private func liveCaptionMaxContentSize(mode: LiveCaptionPanelMode? = nil) -> NSSize {
        let mode = mode ?? liveCaptionPanelMode
        switch mode {
        case .expanded:
            var size = NSSize(width: 900, height: 1200)
            if !liveCaptionChromeVisible {
                size.height -= LiveCaptionFloatingPanel.expandedHeaderBandHeight
            }
            return size
        case .compact:
            return NSSize(width: 900, height: liveCaptionDefaultContentSize(mode: mode).height)
        }
    }

    private func resizeLiveCaptionWindowForChromeVisibility(previousChromeVisible: Bool) {
        guard let liveCaptionWindow = managedWindows.liveCaptionWindow else {
            return
        }

        let previousContentSize = liveCaptionWindow.contentRect(forFrameRect: liveCaptionWindow.frame).size
        let previousDefaultContentSize = liveCaptionDefaultContentSize(
            mode: .expanded,
            chromeVisible: previousChromeVisible
        )
        let defaultContentSize = liveCaptionDefaultContentSize(mode: .expanded)
        let heightDelta = defaultContentSize.height - previousDefaultContentSize.height
        let maxContentSize = liveCaptionMaxContentSize(mode: .expanded)
        let targetContentSize = NSSize(
            width: Swift.min(
                Swift.max(previousContentSize.width, defaultContentSize.width),
                maxContentSize.width
            ),
            height: Swift.min(
                Swift.max(previousContentSize.height + heightDelta, defaultContentSize.height),
                maxContentSize.height
            )
        )

        let previousBottomY = liveCaptionWindow.frame.origin.y
        let previousMaxX = liveCaptionWindow.frame.maxX
        applyLiveCaptionContentSizeConstraints(liveCaptionWindow, mode: .expanded)
        var contentRect = liveCaptionWindow.contentRect(forFrameRect: liveCaptionWindow.frame)
        contentRect.size = targetContentSize
        var targetFrame = liveCaptionWindow.frameRect(forContentRect: contentRect)
        targetFrame.origin.x = previousMaxX - targetFrame.width
        targetFrame.origin.y = previousBottomY
        liveCaptionWindow.setFrame(targetFrame, display: true)
    }

    private func hideLiveCaptionWindow() {
        closeLiveCaptionWindow()
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
        window.orderOut(nil)
        window.contentView = nil
        window.delegate = nil
        window.close()
        restoreAccessoryActivationPolicyIfPossible()
    }

    private func resizeLiveCaptionWindowToContent(animated: Bool = false, usesFittingSize: Bool = true) {
        guard let liveCaptionWindow = managedWindows.liveCaptionWindow,
              let hostingView = liveCaptionWindow.contentView as? LiveCaptionPassthroughHostingView<AnyView> else {
            managedWindows.liveCaptionWindow?.setContentSize(liveCaptionDefaultContentSize())
            if let liveCaptionWindow = managedWindows.liveCaptionWindow {
                positionLiveCaptionWindow(liveCaptionWindow)
            }
            return
        }

        let fittingSize: NSSize
        if usesFittingSize {
            hostingView.layoutSubtreeIfNeeded()
            fittingSize = hostingView.fittingSize
        } else {
            fittingSize = liveCaptionDefaultContentSize()
        }

        // Capture the visual bottom/right edges BEFORE resizing. The
        // panel is parked near the dock and screen edge; mode morphs should
        // feel anchored there instead of popping from the top-left.
        let previousBottomY = liveCaptionWindow.frame.origin.y
        let previousMaxX = liveCaptionWindow.frame.maxX
        applyLiveCaptionContentSizeConstraints(liveCaptionWindow, mode: liveCaptionPanelMode)
        let defaultContentSize = liveCaptionDefaultContentSize()
        let targetContentSize = NSSize(
            width: max(defaultContentSize.width, fittingSize.width),
            height: max(defaultContentSize.height, fittingSize.height)
        )
        var contentRect = liveCaptionWindow.contentRect(forFrameRect: liveCaptionWindow.frame)
        contentRect.size = targetContentSize
        var targetFrame = liveCaptionWindow.frameRect(forContentRect: contentRect)
        targetFrame.origin.x = previousMaxX - targetFrame.width
        targetFrame.origin.y = previousBottomY

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              animated,
              liveCaptionWindow.isVisible else {
            liveCaptionWindow.setFrame(targetFrame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = DT.Motion.liveCaptionModeSwap
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1)
            context.allowsImplicitAnimation = true
            liveCaptionWindow.animator().setFrame(targetFrame, display: true)
        }
    }

    private func liveCaptionRootView() -> AnyView {
        // No `windowPadding`: pinning the SwiftUI tree flush to the
        // NSWindow frame keeps the visible rounded edge aligned with
        // the AppKit resize hit-zone. NSWindow draws its own shadow
        // outside the frame (via `panel.hasShadow = true`).
        AnyView(
            ThemedHost {
                LiveCaptionFloatingPanelHost(appDelegate: self, recorder: recorder)
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
        // AppKit can emit screen-parameter notifications while a hide/show
        // operation is already moving the panel. Let the in-flight sync finish
        // instead of re-entering NSWindow frame/order APIs.
        guard !isSyncingPanelVisibility else { return }
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
        let canonicalActive = Set(active.map(BundleCollapser.parent(of:)))
        autoPromptSuppressedUntilInactiveBundleIDs.formIntersection(canonicalActive)
        handleDetectedMeetingRecordingActivity(active)
        promptedAutoPromptKeyByBundleID = promptedAutoPromptKeyByBundleID.filter {
            canonicalActive.contains(BundleCollapser.parent(of: $0.key))
        }

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

    func suppressAutoPromptForCurrentRecordingSourceUntilInactive() {
        let explicitSources = [
            recorder.selectedApp?.id,
            recorder.detectedMeetingRecordingContext?.appID,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let sourceIDs = explicitSources.isEmpty ? Array(effectiveActiveAudioBundleIDs) : explicitSources
        let canonicalSources = sourceIDs.map(BundleCollapser.parent(of:))
        guard !canonicalSources.isEmpty else { return }

        autoPromptSuppressedUntilInactiveBundleIDs.formUnion(canonicalSources)
        browserAutoPromptTask?.cancel()
        hiddenPanelAutoPromptTask?.cancel()
        hiddenPanelAutoPromptTask = nil
    }

    private func handleDetectedMeetingRecordingActivity(_ active: Set<String>) {
        guard let context = recorder.detectedMeetingRecordingContext,
              recorder.state == .recording else {
            detectedMeetingAutoStopTask?.cancel()
            detectedMeetingAutoStopTask = nil
            return
        }

        let targetID = BundleCollapser.parent(of: context.appID)
        let isBrowserContext = BrowserMeetingDetector.supports(bundleID: targetID)
        guard isBrowserContext || !active.contains(targetID) else {
            detectedMeetingAutoStopTask?.cancel()
            detectedMeetingAutoStopTask = nil
            return
        }

        guard detectedMeetingAutoStopTask == nil else { return }
        let grace = detectedMeetingAutoStopGraceDuration
        detectedMeetingAutoStopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var sleepDuration = grace
            var browserContextMissCount = 0

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(sleepDuration))
                guard !Task.isCancelled else { return }
                guard self.recorder.state == .recording,
                      let current = self.recorder.detectedMeetingRecordingContext,
                      current == context else {
                    self.detectedMeetingAutoStopTask = nil
                    return
                }

                let latestActive = self.effectiveActiveAudioBundleIDs
                if isBrowserContext {
                    sleepDuration = self.browserMeetingPollInterval
                    if await self.browserMeetingStillLooksActive(current) {
                        browserContextMissCount = 0
                        continue
                    }

                    if latestActive.contains(targetID) {
                        browserContextMissCount += 1
                        guard browserContextMissCount >= 2 else { continue }
                    }
                } else {
                    guard !latestActive.contains(targetID) else {
                        self.detectedMeetingAutoStopTask = nil
                        return
                    }
                }

                self.recorder.requestAutoStopForDetectedMeetingIfNeeded()
                self.detectedMeetingAutoStopTask = nil
                return
            }
        }
    }

    private func browserMeetingStillLooksActive(_ context: DetectedMeetingRecordingContext) async -> Bool {
        guard BrowserMeetingDetector.supports(bundleID: context.appID) else { return false }
        if let promptTitle = meetingLabelOverride(for: context.appID) {
            return context.browserSessionKey == nil ||
                context.browserSessionKey == uiTestBrowserMeetingSessionKey(promptTitle: promptTitle)
        }
        guard let match = await BrowserMeetingDetector.inferMeetingMatch(
            bundleID: context.appID,
            browserName: context.appName
        ) else { return false }
        guard let browserSessionKey = context.browserSessionKey else {
            return match.suggestionTitle == context.promptTitle
        }
        return match.sessionKey == browserSessionKey
    }

    @discardableResult
    private func promptForMeetingAudioIfNeeded(_ active: Set<String>) -> Bool {
        guard recorder.state == .idle else { return false }
        guard let app = AudioRecorder.autoPromptCandidate(from: recorder.runningApps, active: active) else { return false }
        guard !autoPromptSuppressedUntilInactiveBundleIDs.contains(BundleCollapser.parent(of: app.id)) else {
            return false
        }
        let target = AutoPromptTarget(
            app: app,
            promptKey: "meeting:\(app.id)",
            promptTitle: nil,
            browserSessionKey: nil
        )
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
                promptTitle: target.promptTitle ?? target.app.name,
                browserSessionKey: target.browserSessionKey
            )
        } else if let promptTitle = target.promptTitle {
            recorder.suggestRecording(
                for: target.app,
                promptTitle: promptTitle,
                browserSessionKey: target.browserSessionKey
            )
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
            guard !autoPromptSuppressedUntilInactiveBundleIDs.contains(BundleCollapser.parent(of: app.id)) else {
                continue
            }

            if let promptTitle = meetingLabelOverride(for: app.id) {
                let browserSessionKey = uiTestBrowserMeetingSessionKey(promptTitle: promptTitle)
                return AutoPromptTarget(
                    app: app,
                    promptKey: "browser:\(app.id):\(browserSessionKey)",
                    promptTitle: promptTitle,
                    browserSessionKey: browserSessionKey
                )
            }

            guard BrowserMeetingDetector.supports(bundleID: app.id) else { continue }
            guard let match = await BrowserMeetingDetector.inferMeetingMatch(
                bundleID: app.id,
                browserName: app.name
            ) else { continue }

            return AutoPromptTarget(
                app: app,
                promptKey: "browser:\(app.id):\(match.sessionKey)",
                promptTitle: match.suggestionTitle,
                browserSessionKey: match.sessionKey
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

    private func uiTestBrowserMeetingSessionKey(promptTitle: String) -> String {
        "uitest:\(promptTitle.lowercased())"
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

    func windowWillResize(_ sender: NSWindow, toFrameSize frameSize: NSSize) -> NSSize {
        guard sender === managedWindows.liveCaptionWindow else {
            return frameSize
        }
        return liveCaptionResizeFrameSize(sender, requestedFrameSize: frameSize)
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        guard window === managedWindows.liveCaptionWindow else {
            return true
        }
        return false
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

private struct LiveCaptionFloatingPanelHost: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var recorder: AudioRecorder

    var body: some View {
        LiveCaptionFloatingPanel(
            recorder: recorder,
            mode: appDelegate.liveCaptionPanelMode,
            onToggleMode: {
                appDelegate.toggleLiveCaptionPanelMode()
            },
            onClose: {
                appDelegate.setLiveCaptionPanelPresented(false)
            },
            onChromeVisibilityChange: { visible in
                appDelegate.setLiveCaptionChromeVisible(visible)
            }
        )
        .environmentObject(AppConfig.shared)
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
    var refusesFirstResponder = false

    override var acceptsFirstResponder: Bool {
        refusesFirstResponder ? false : super.acceptsFirstResponder
    }

    override func becomeFirstResponder() -> Bool {
        refusesFirstResponder ? false : super.becomeFirstResponder()
    }

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
