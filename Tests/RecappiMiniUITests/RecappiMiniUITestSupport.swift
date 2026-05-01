import AppKit
import XCTest

enum UITestIDs {
    enum Settings {
        static let authStatus = "recappi.settings.authStatus"
        static let authStatusText = "recappi.settings.authStatusText"
        static let autoPromptToggle = "recappi.settings.autoPromptToggle"
        static let signInGoogleButton = "recappi.settings.signInGoogleButton"
        static let signInGitHubButton = "recappi.settings.signInGitHubButton"
        static let accountActionsMenu = "recappi.settings.accountActionsMenu"
        static let reconnectButton = "recappi.settings.reconnectButton"
        static let signOutButton = "recappi.settings.signOutButton"
        static let openCloudButton = "recappi.settings.openCloudButton"
        static let billingUsage = "recappi.settings.billingUsage"
    }

    enum Panel {
        static let audioSourcePicker = "recappi.panel.audioSourcePicker"
        static let settingsButton = "recappi.panel.settingsButton"
        static let closeButton = "recappi.panel.closeButton"
        static let recordingSuggestion = "recappi.panel.recordingSuggestion"
        static let meetingPrompt = "recappi.panel.meetingPrompt"
        static let recordButton = "recappi.panel.recordButton"
        static let stopButton = "recappi.panel.stopButton"
        static let processingTitle = "recappi.panel.processingTitle"
        static let doneTitle = "recappi.panel.doneTitle"
        static let errorTitle = "recappi.panel.errorTitle"
    }

    enum Cloud {
        static let window = "recappi.cloud.window"
        static let authStatus = "recappi.cloud.authStatus"
        static let refreshButton = "recappi.cloud.refreshButton"
        static let billingStatus = "recappi.cloud.billingStatus"
        static let billingButton = "recappi.cloud.billingButton"
        static let plansButton = "recappi.cloud.plansButton"
        static let signInGoogleButton = "recappi.cloud.signInGoogleButton"
        static let signInGitHubButton = "recappi.cloud.signInGitHubButton"
        static let reconnectButton = "recappi.cloud.reconnectButton"
        static let recordingsList = "recappi.cloud.recordingsList"
        static let recordingRowPrefix = "recappi.cloud.recordingRow."
        static let loadMoreButton = "recappi.cloud.loadMoreButton"
        static let latestJobStatus = "recappi.cloud.latestJobStatus"
        static let transcriptText = "recappi.cloud.transcriptText"
        static let jumpToSummaryButton = "recappi.cloud.jumpToSummaryButton"
        static let jumpToTranscriptButton = "recappi.cloud.jumpToTranscriptButton"
        static let loadTranscriptButton = "recappi.cloud.loadTranscriptButton"
        static let recordingInfoButton = "recappi.cloud.recordingInfoButton"
        static let moreActionsButton = "recappi.cloud.moreActionsButton"
        static let copyTranscriptButton = "recappi.cloud.copyTranscriptButton"
        static let downloadAudioButton = "recappi.cloud.downloadAudioButton"
        static let syncToLocalButton = "recappi.cloud.syncToLocalButton"
        static let deleteButton = "recappi.cloud.deleteButton"
    }
}

enum UITestArtifacts {
    static var recordingsRoot: URL {
        if let override = UITestPaths.recordingsRootOverrideValue, !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Recappi Mini", isDirectory: true)
    }

    static func sessionNames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            at: recordingsRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        return Set(names.map(\.lastPathComponent))
    }

    static func newestSession(excluding baseline: Set<String>) throws -> URL {
        let urls = try FileManager.default.contentsOfDirectory(
            at: recordingsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let candidates = urls.filter { !baseline.contains($0.lastPathComponent) }
        return try XCTUnwrap(
            candidates.max {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs < rhs
            },
            "Expected a new recording session directory."
        )
    }
}

@MainActor
extension XCTestCase {
    func launchRecappiApp(
        authToken: String? = nil,
        simulatedAutoPromptApp: (bundleID: String, name: String)? = nil,
        simulatedAutoPromptMeetingLabel: String? = nil,
        hiddenAutoPromptSnoozeSeconds: TimeInterval? = nil,
        detectedMeetingAutoStopGraceSeconds: TimeInterval? = nil,
        openCloudWindowOnLaunch: Bool = false
    ) -> XCUIApplication {
        terminateExistingRecappiInstances()

        let app = XCUIApplication(url: UITestPaths.appBundle)
        app.launchEnvironment["RECAPPI_UI_TEST"] = "1"
        app.launchEnvironment["RECAPPI_TEST_AUDIO_FIXTURE"] = UITestPaths.recordingFixture.path
        try? FileManager.default.removeItem(at: UITestPaths.autoPromptCommandFile)
        app.launchEnvironment["RECAPPI_UI_TEST_COMMAND_FILE"] = UITestPaths.autoPromptCommandFile.path

        let effectiveAuthToken = authToken ?? UITestPaths.liveAuthTokenValue
        if let effectiveAuthToken, !effectiveAuthToken.isEmpty {
            app.launchEnvironment["RECAPPI_TEST_AUTH_TOKEN"] = effectiveAuthToken
        }
        if let backend = UITestPaths.backendOverrideValue, !backend.isEmpty {
            app.launchEnvironment["RECAPPI_TEST_BACKEND_URL"] = backend
        }
        if let simulatedAutoPromptApp {
            app.launchEnvironment["RECAPPI_TEST_AUTO_PROMPT_BUNDLE_ID"] = simulatedAutoPromptApp.bundleID
            app.launchEnvironment["RECAPPI_TEST_AUTO_PROMPT_APP_NAME"] = simulatedAutoPromptApp.name
        }
        if let simulatedAutoPromptMeetingLabel, !simulatedAutoPromptMeetingLabel.isEmpty {
            app.launchEnvironment["RECAPPI_TEST_AUTO_PROMPT_MEETING_LABEL"] = simulatedAutoPromptMeetingLabel
        }
        if let hiddenAutoPromptSnoozeSeconds {
            app.launchEnvironment["RECAPPI_TEST_HIDDEN_AUTOPROMPT_SNOOZE_SECONDS"] = String(hiddenAutoPromptSnoozeSeconds)
        }
        if let detectedMeetingAutoStopGraceSeconds {
            app.launchEnvironment["RECAPPI_TEST_DETECTED_MEETING_AUTOSTOP_GRACE_SECONDS"] = String(detectedMeetingAutoStopGraceSeconds)
        }
        if openCloudWindowOnLaunch {
            app.launchEnvironment["RECAPPI_TEST_OPEN_CLOUD_WINDOW"] = "1"
        }

        app.launch()
        addTeardownBlock {
            if app.state != .notRunning {
                app.terminate()
            }
        }
        return app
    }

    func terminateExistingRecappiInstances() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.recappi.mini")
        for app in running {
            app.forceTerminate()
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.recappi.mini").isEmpty {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    func uiElement(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func openSettings(from app: XCUIApplication) {
        let button = app.buttons[UITestIDs.Panel.settingsButton]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "Expected in-panel Settings button.")
        button.click()
        dismissSecurityAgentIfPresent()
        XCTAssertTrue(uiElement(app, id: UITestIDs.Settings.authStatus).waitForExistence(timeout: 15), "Expected Settings auth status.")
    }

    func waitForSignedInStatus(in app: XCUIApplication, timeout: TimeInterval = 25) {
        let status = uiElement(app, id: UITestIDs.Settings.authStatus)
        XCTAssertTrue(status.waitForExistence(timeout: timeout), "Expected auth status element.")

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSecurityAgentIfPresent(timeout: 0.2)

            let statusText = authStatusSnapshot(from: status)
            if statusText.localizedCaseInsensitiveContains("expires") {
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTFail("Expected signed-in auth status, got: \(status.label)")
    }

    func waitForFailedStatus(in app: XCUIApplication, timeout: TimeInterval = 15) {
        let status = uiElement(app, id: UITestIDs.Settings.authStatus)
        XCTAssertTrue(status.waitForExistence(timeout: timeout), "Expected auth status element.")

        let failureMarkers = [
            "Authentication failed",
            "Session expired",
            "Signed out",
            "did not return a usable session"
        ]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSecurityAgentIfPresent(timeout: 0.2)

            let statusText = authStatusSnapshot(from: status)
            if failureMarkers.contains(where: statusText.localizedCaseInsensitiveContains) {
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTFail("Expected failed auth status, got: \(status.label)")
    }

    func ensureSignedInByReauthIfNeeded(
        in app: XCUIApplication,
        timeout: TimeInterval = 90
    ) throws {
        let status = uiElement(app, id: UITestIDs.Settings.authStatus)
        XCTAssertTrue(status.waitForExistence(timeout: timeout), "Expected auth status element.")

        let deadline = Date().addingTimeInterval(timeout)
        var attemptedInteractiveLogin = false

        while Date() < deadline {
            dismissSecurityAgentIfPresent(timeout: 0.2)

            let statusText = authStatusSnapshot(from: status)
            if statusText.localizedCaseInsensitiveContains("expires") {
                return
            }

            if !attemptedInteractiveLogin {
                let reconnect = app.buttons[UITestIDs.Settings.reconnectButton]
                if reconnect.exists && reconnect.isEnabled {
                    guard UITestPaths.allowInteractiveOAuth else {
                        throw XCTSkip(
                            "Interactive OAuth is manual-only in unattended runs. " +
                            "Seed RECAPPI_TEST_AUTH_TOKEN or set RECAPPI_TEST_ALLOW_INTERACTIVE_OAUTH=1 to opt in."
                        )
                    }
                    reconnect.click()
                    attemptedInteractiveLogin = true
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                    continue
                }

                let google = app.buttons[UITestIDs.Settings.signInGoogleButton]
                if google.exists && google.isEnabled {
                    guard UITestPaths.allowInteractiveOAuth else {
                        throw XCTSkip(
                            "Interactive OAuth is manual-only in unattended runs. " +
                            "Seed RECAPPI_TEST_AUTH_TOKEN or set RECAPPI_TEST_ALLOW_INTERACTIVE_OAUTH=1 to opt in."
                        )
                    }
                    google.click()
                    attemptedInteractiveLogin = true
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                    continue
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTFail("Expected signed-in auth status after interactive login, got: \(authStatusSnapshot(from: status))")
    }

    func signOut(in app: XCUIApplication) {
        if app.buttons[UITestIDs.Settings.signOutButton].exists == false {
            let menu = app.buttons[UITestIDs.Settings.accountActionsMenu]
            XCTAssertTrue(menu.waitForExistence(timeout: 10), "Expected account actions menu.")
            menu.click()
        }
        let button = app.buttons[UITestIDs.Settings.signOutButton]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Expected Sign out button.")
        button.click()
    }

    func closeSettingsWindow(in app: XCUIApplication) {
        app.typeKey("w", modifierFlags: [.command])
        XCTAssertTrue(app.buttons[UITestIDs.Panel.recordButton].waitForExistence(timeout: 15), "Expected panel to return after closing Settings.")
    }

    func hidePanel(in app: XCUIApplication) {
        let closeButton = app.buttons[UITestIDs.Panel.closeButton]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 10), "Expected panel close button.")
        closeButton.click()
        XCTAssertTrue(waitForNonExistence(of: closeButton, timeout: 10), "Expected panel close button to disappear after hiding the panel.")
    }

    func postSimulatedAutoPrompt(
        bundleID: String,
        appName: String,
        meetingLabel: String? = nil,
        active: Bool
    ) {
        var userInfo: [String: Any] = [
            "bundleID": bundleID,
            "appName": appName,
            "active": active,
        ]
        if let meetingLabel, !meetingLabel.isEmpty {
            userInfo["meetingLabel"] = meetingLabel
        }
        let data = try! JSONSerialization.data(withJSONObject: userInfo, options: [.sortedKeys])
        try! FileManager.default.createDirectory(
            at: UITestPaths.autoPromptCommandFile.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try! data.write(to: UITestPaths.autoPromptCommandFile, options: [.atomic])
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
    }

    func startAndStopFixtureRecording(in app: XCUIApplication) {
        let recordButton = app.buttons[UITestIDs.Panel.recordButton]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 15), "Expected Record button.")
        recordButton.click()

        let stopButton = app.buttons[UITestIDs.Panel.stopButton]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 15), "Expected Stop button.")
        stopButton.click()
    }

    func waitForCompletion(in app: XCUIApplication, timeout: TimeInterval = 180) {
        let done = uiElement(app, id: UITestIDs.Panel.doneTitle)
        if done.waitForExistence(timeout: timeout) {
            return
        }

        let error = uiElement(app, id: UITestIDs.Panel.errorTitle)
        let message = error.exists ? error.label : "Timed out waiting for done state."
        XCTFail("Expected successful processing, got \(message)")
    }

    func attachArtifacts(for sessionDir: URL, named name: String) {
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: sessionDir.path).sorted().joined(separator: "\n")) ?? "(missing session dir)"
        let attachment = XCTAttachment(string: listing)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func dismissSecurityAgentIfPresent(timeout: TimeInterval = 2) {
        let securityAgent = XCUIApplication(bundleIdentifier: "com.apple.SecurityAgent")
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if clickFirstButton(named: "Always Allow", in: securityAgent) {
                return
            }

            if clickFirstButton(named: "Allow", in: securityAgent) {
                return
            }

            if clickFirstButton(named: "OK", in: securityAgent) {
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func clickFirstButton(named name: String, in app: XCUIApplication) -> Bool {
        guard app.state != .notRunning else { return false }

        let button = app
            .descendants(matching: .button)
            .matching(NSPredicate(format: "label == %@", name))
            .firstMatch
        guard button.exists else { return false }
        button.click()
        return true
    }

    @discardableResult
    func waitForNonExistence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    private func authStatusSnapshot(from element: XCUIElement) -> String {
        [element.label, element.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}
