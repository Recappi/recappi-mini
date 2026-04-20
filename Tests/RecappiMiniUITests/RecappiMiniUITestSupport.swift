import XCTest

enum UITestIDs {
    enum Settings {
        static let cookieField = "recappi.settings.cookieField"
        static let verifyButton = "recappi.settings.verifyButton"
        static let authStatus = "recappi.settings.authStatus"
        static let authStatusText = "recappi.settings.authStatusText"
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
        cookie: String? = nil,
        disableSummary: Bool = false,
        enableSummaryStub: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication(url: UITestPaths.appBundle)
        app.launchEnvironment["RECAPPI_UI_TEST"] = "1"
        app.launchEnvironment["RECAPPI_TEST_AUDIO_FIXTURE"] = UITestPaths.recordingFixture.path
        app.launchEnvironment["RECAPPI_TEST_DISABLE_SUMMARY"] = disableSummary ? "1" : "0"
        app.launchEnvironment["RECAPPI_TEST_SUMMARY_STUB"] = enableSummaryStub ? "1" : "0"

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

    func uiElement(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func openSettings(from app: XCUIApplication) {
        let button = app.buttons[UITestIDs.Panel.settingsButton]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "Expected in-panel Settings button.")
        button.click()
        XCTAssertTrue(uiElement(app, id: UITestIDs.Settings.cookieField).waitForExistence(timeout: 15), "Expected Settings cookie field.")
    }

    func verifySession(in app: XCUIApplication, expecting text: String, timeout: TimeInterval = 25) {
        let verifyButton = app.buttons[UITestIDs.Settings.verifyButton]
        XCTAssertTrue(verifyButton.waitForExistence(timeout: 10), "Expected Verify Session button.")
        verifyButton.click()

        let status = uiElement(app, id: UITestIDs.Settings.authStatus)
        XCTAssertTrue(status.waitForExistence(timeout: timeout), "Expected auth status element.")
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        expectation(for: predicate, evaluatedWith: status)
        waitForExpectations(timeout: timeout)
    }

    func verifySessionSucceeds(in app: XCUIApplication, timeout: TimeInterval = 25) {
        let verifyButton = app.buttons[UITestIDs.Settings.verifyButton]
        XCTAssertTrue(verifyButton.waitForExistence(timeout: 10), "Expected Verify Session button.")
        verifyButton.click()

        let status = uiElement(app, id: UITestIDs.Settings.authStatus)
        XCTAssertTrue(status.waitForExistence(timeout: timeout), "Expected auth status element.")
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "expires", "expires")
        expectation(for: predicate, evaluatedWith: status)
        waitForExpectations(timeout: timeout)
    }

    func verifySessionFails(in app: XCUIApplication, timeout: TimeInterval = 15) {
        let verifyButton = app.buttons[UITestIDs.Settings.verifyButton]
        XCTAssertTrue(verifyButton.waitForExistence(timeout: 10), "Expected Verify Session button.")
        verifyButton.click()

        let status = uiElement(app, id: UITestIDs.Settings.authStatus)
        XCTAssertTrue(status.waitForExistence(timeout: timeout), "Expected auth status element.")
        let predicate = NSPredicate(
            format: """
            label CONTAINS[c] %@ OR value CONTAINS[c] %@ OR
            label CONTAINS[c] %@ OR value CONTAINS[c] %@
            """,
            "Cookie invalid",
            "Cookie invalid",
            "Session expired",
            "Session expired"
        )
        expectation(for: predicate, evaluatedWith: status)
        waitForExpectations(timeout: timeout)
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
