import XCTest

@MainActor
final class AAARecappiMiniLaunchSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchesBuiltAppBundle() throws {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: UITestPaths.appBundle.path),
            "Expected built app bundle at \(UITestPaths.appBundle.path). Run scripts/build-app.sh first."
        )

        let app = XCUIApplication(url: UITestPaths.appBundle)
        app.launchEnvironment["RECAPPI_UI_TEST"] = "1"
        app.launchEnvironment["RECAPPI_TEST_AUDIO_FIXTURE"] = UITestPaths.recordingFixture.path
        app.launchEnvironment["RECAPPI_TEST_UPLOAD_FIXTURE"] = UITestPaths.uploadFixture.path
        if let authToken = UITestPaths.liveAuthTokenValue, !authToken.isEmpty {
            app.launchEnvironment["RECAPPI_TEST_AUTH_TOKEN"] = authToken
        }
        if let backend = ProcessInfo.processInfo.environment["RECAPPI_TEST_BACKEND_URL"], !backend.isEmpty {
            app.launchEnvironment["RECAPPI_TEST_BACKEND_URL"] = backend
        }

        app.launch()

        let launched =
            app.wait(for: .runningForeground, timeout: 15) ||
            app.wait(for: .runningBackground, timeout: 15)

        XCTAssertTrue(launched, "Expected Recappi Mini to launch from the built app bundle.")

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "launch-smoke"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.terminate()
    }

    func testAutoPromptSuggestionKeepsManualRecordControls() throws {
        let app = launchRecappiApp(
            authToken: "",
            simulatedAutoPromptApp: (bundleID: "com.apple.Safari", name: "Safari"),
            simulatedAutoPromptMeetingLabel: "Google Meet in Safari"
        )

        let suggestion = uiElement(app, id: UITestIDs.Panel.recordingSuggestion)
        XCTAssertTrue(suggestion.waitForExistence(timeout: 15), "Expected auto-prompt suggestion banner.")
        let suggestionText = [suggestion.label, suggestion.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            suggestionText.localizedCaseInsensitiveContains("Google Meet in Safari"),
            "Expected meeting-specific suggestion text, got: \(suggestionText)"
        )

        let sourcePicker = uiElement(app, id: UITestIDs.Panel.audioSourcePicker)
        XCTAssertTrue(sourcePicker.waitForExistence(timeout: 10), "Expected source picker to remain visible.")

        let recordButton = app.buttons[UITestIDs.Panel.recordButton]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 10), "Expected regular record button to remain available.")
        recordButton.click()

        let stopButton = app.buttons[UITestIDs.Panel.stopButton]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 15), "Expected recording to start from the manual record button.")

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "auto-prompt-manual-record"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHiddenPanelAutoPromptSelectsAppAndRemovesSuggestionBanner() throws {
        let app = launchRecappiApp(authToken: "")
        hidePanel(in: app)

        postSimulatedAutoPrompt(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            meetingLabel: "Google Meet in Safari",
            active: true
        )

        let sourcePicker = uiElement(app, id: UITestIDs.Panel.audioSourcePicker)
        XCTAssertTrue(sourcePicker.waitForExistence(timeout: 15), "Expected panel to reappear after hidden auto-prompt.")
        let sourceText = [sourcePicker.label, sourcePicker.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            sourceText.localizedCaseInsensitiveContains("Safari"),
            "Expected hidden auto-prompt to preselect Safari, got: \(sourceText)"
        )

        let suggestion = uiElement(app, id: UITestIDs.Panel.recordingSuggestion)
        XCTAssertFalse(suggestion.exists, "Expected hidden auto-prompt to skip the suggestion banner once the source is preselected.")

        let meetingPrompt = uiElement(app, id: UITestIDs.Panel.meetingPrompt)
        XCTAssertTrue(meetingPrompt.waitForExistence(timeout: 5), "Expected hidden auto-prompt to explain that Safari may be in a meeting.")
        let promptText = [meetingPrompt.label, meetingPrompt.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            promptText.localizedCaseInsensitiveContains("may be in a meeting"),
            "Expected meeting prompt copy, got: \(promptText)"
        )

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "hidden-auto-prompt-preselects-app"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHiddenPanelIgnoresBrowserAudioWithoutMeetingContext() throws {
        let app = launchRecappiApp(authToken: "")
        hidePanel(in: app)

        postSimulatedAutoPrompt(
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            active: true
        )

        let sourcePicker = uiElement(app, id: UITestIDs.Panel.audioSourcePicker)
        XCTAssertTrue(
            waitForNonExistence(of: sourcePicker, timeout: 2.5),
            "Expected plain browser audio to stay quiet until a meeting tab is detected."
        )

        let suggestion = uiElement(app, id: UITestIDs.Panel.recordingSuggestion)
        XCTAssertFalse(suggestion.exists, "Expected no suggestion banner for non-meeting browser audio.")

        let meetingPrompt = uiElement(app, id: UITestIDs.Panel.meetingPrompt)
        XCTAssertFalse(meetingPrompt.exists, "Expected no meeting prompt for non-meeting browser audio.")
    }

    func testHiddenPanelRepromptsForSameBrowserAfterSnooze() throws {
        let app = launchRecappiApp(
            authToken: "",
            simulatedAutoPromptApp: (bundleID: "com.google.Chrome", name: "Google Chrome"),
            simulatedAutoPromptMeetingLabel: "Google Meet in Chrome",
            hiddenAutoPromptSnoozeSeconds: 0.2
        )

        let closeButton = app.buttons[UITestIDs.Panel.closeButton]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 15), "Expected launch-time panel for the active browser.")

        let launchSuggestion = uiElement(app, id: UITestIDs.Panel.recordingSuggestion)
        XCTAssertTrue(launchSuggestion.waitForExistence(timeout: 10), "Expected launch-time browser meeting prompt to use the suggestion banner.")
        let suggestionText = [launchSuggestion.label, launchSuggestion.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            suggestionText.localizedCaseInsensitiveContains("Google Meet in Chrome"),
            "Expected launch-time suggestion to mention Chrome meeting context, got: \(suggestionText)"
        )

        let sourcePicker = uiElement(app, id: UITestIDs.Panel.audioSourcePicker)
        XCTAssertTrue(sourcePicker.waitForExistence(timeout: 10), "Expected source picker to be visible before hiding the panel.")
        let initialSourceText = [sourcePicker.label, sourcePicker.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            initialSourceText.localizedCaseInsensitiveContains("All system audio"),
            "Expected launch-time prompt to preserve the current manual source, got: \(initialSourceText)"
        )

        hidePanel(in: app)

        XCTAssertTrue(
            sourcePicker.waitForExistence(timeout: 15),
            "Expected hidden panel to reappear for the same active browser after the snooze window."
        )

        let sourceText = [sourcePicker.label, sourcePicker.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            sourceText.localizedCaseInsensitiveContains("Chrome"),
            "Expected reprompted hidden panel to stay focused on Chrome, got: \(sourceText)"
        )

        let suggestion = uiElement(app, id: UITestIDs.Panel.recordingSuggestion)
        XCTAssertFalse(suggestion.exists, "Expected hidden-panel reprompt to preselect the app instead of showing the suggestion banner.")

        let meetingPrompt = uiElement(app, id: UITestIDs.Panel.meetingPrompt)
        XCTAssertTrue(meetingPrompt.waitForExistence(timeout: 5), "Expected hidden-panel reprompt to keep a meeting explanation on the panel.")

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "hidden-panel-reprompts-same-browser"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
