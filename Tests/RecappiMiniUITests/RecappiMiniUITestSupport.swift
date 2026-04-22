import AppKit
import XCTest

enum UITestIDs {
    enum Settings {
        static let authStatus = "recappi.settings.authStatus"
        static let authStatusText = "recappi.settings.authStatusText"
        static let backendField = "recappi.settings.backendField"
        static let signInGoogleButton = "recappi.settings.signInGoogleButton"
        static let signInGitHubButton = "recappi.settings.signInGitHubButton"
        static let reconnectButton = "recappi.settings.reconnectButton"
        static let signOutButton = "recappi.settings.signOutButton"
        static let manualBearerField = "recappi.settings.manualBearerField"
        static let importBearerButton = "recappi.settings.importBearerButton"
    }

    enum Panel {
        static let settingsButton = "recappi.panel.settingsButton"
        static let recordButton = "recappi.panel.recordButton"
        static let stopButton = "recappi.panel.stopButton"
        static let processingTitle = "recappi.panel.processingTitle"
        static let doneTitle = "recappi.panel.doneTitle"
        static let errorTitle = "recappi.panel.errorTitle"
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
        authToken: String? = nil
    ) -> XCUIApplication {
        terminateExistingRecappiInstances()

        let app = XCUIApplication(url: UITestPaths.appBundle)
        app.launchEnvironment["RECAPPI_UI_TEST"] = "1"
        app.launchEnvironment["RECAPPI_TEST_AUDIO_FIXTURE"] = UITestPaths.recordingFixture.path

        let effectiveAuthToken = authToken ?? UITestPaths.liveAuthTokenValue
        if let effectiveAuthToken, !effectiveAuthToken.isEmpty {
            app.launchEnvironment["RECAPPI_TEST_AUTH_TOKEN"] = effectiveAuthToken
        }
        if let backend = UITestPaths.backendOverrideValue, !backend.isEmpty {
            app.launchEnvironment["RECAPPI_TEST_BACKEND_URL"] = backend
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
        let button = app.buttons[UITestIDs.Settings.signOutButton]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Expected Sign out button.")
        button.click()
    }

    func closeSettingsWindow(in app: XCUIApplication) {
        app.typeKey("w", modifierFlags: [.command])
        XCTAssertTrue(app.buttons[UITestIDs.Panel.recordButton].waitForExistence(timeout: 15), "Expected panel to return after closing Settings.")
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

    private func authStatusSnapshot(from element: XCUIElement) -> String {
        [element.label, element.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}
