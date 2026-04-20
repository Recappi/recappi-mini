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
        static let manualCookieField = "recappi.settings.manualCookieField"
        static let importBearerButton = "recappi.settings.importBearerButton"
        static let exchangeCookieButton = "recappi.settings.exchangeCookieButton"
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
        authToken: String? = nil,
        cookie: String? = nil
    ) -> XCUIApplication {
        terminateExistingRecappiInstances()

        let app = XCUIApplication(url: UITestPaths.appBundle)
        app.launchEnvironment["RECAPPI_UI_TEST"] = "1"
        app.launchEnvironment["RECAPPI_TEST_AUDIO_FIXTURE"] = UITestPaths.recordingFixture.path

        let effectiveAuthToken = authToken ?? UITestPaths.liveAuthTokenValue
        if let effectiveAuthToken, !effectiveAuthToken.isEmpty {
            app.launchEnvironment["RECAPPI_TEST_AUTH_TOKEN"] = effectiveAuthToken
        }

        let effectiveCookie = cookie ?? UITestPaths.liveCookieValue
        if let effectiveCookie, !effectiveCookie.isEmpty {
            app.launchEnvironment["RECAPPI_TEST_COOKIE"] = effectiveCookie
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
        XCTAssertTrue(uiElement(app, id: UITestIDs.Settings.authStatus).waitForExistence(timeout: 15), "Expected Settings auth status.")
    }

    func waitForSignedInStatus(in app: XCUIApplication, timeout: TimeInterval = 25) {
        let status = uiElement(app, id: UITestIDs.Settings.authStatus)
        XCTAssertTrue(status.waitForExistence(timeout: timeout), "Expected auth status element.")
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "expires", "expires")
        expectation(for: predicate, evaluatedWith: status)
        waitForExpectations(timeout: timeout)
    }

    func waitForFailedStatus(in app: XCUIApplication, timeout: TimeInterval = 15) {
        let status = uiElement(app, id: UITestIDs.Settings.authStatus)
        XCTAssertTrue(status.waitForExistence(timeout: timeout), "Expected auth status element.")
        let predicate = NSPredicate(
            format: """
            label CONTAINS[c] %@ OR value CONTAINS[c] %@ OR
            label CONTAINS[c] %@ OR value CONTAINS[c] %@ OR
            label CONTAINS[c] %@ OR value CONTAINS[c] %@
            """,
            "Authentication failed",
            "Authentication failed",
            "Session expired",
            "Session expired",
            "Signed out",
            "Signed out"
        )
        expectation(for: predicate, evaluatedWith: status)
        waitForExpectations(timeout: timeout)
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
}
