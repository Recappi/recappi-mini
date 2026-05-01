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
            authToken: "invalid-test-token",
            simulatedAutoPromptApp: (bundleID: "com.apple.Safari", name: "Safari"),
            simulatedAutoPromptMeetingLabel: "Google Meet in Safari",
            detectedMeetingAutoStopGraceSeconds: 0.1
        )

        let suggestion = uiElement(app, id: UITestIDs.Panel.recordingSuggestion)
        XCTAssertTrue(suggestion.waitForExistence(timeout: 15), "Expected auto-prompt suggestion banner.")
        let suggestionText = [suggestion.label, suggestion.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            suggestionText.localizedCaseInsensitiveContains("Google Meet detected in Safari"),
            "Expected meeting-specific suggestion text, got: \(suggestionText)"
        )

        let sourcePicker = uiElement(app, id: UITestIDs.Panel.audioSourcePicker)
        XCTAssertTrue(sourcePicker.waitForExistence(timeout: 10), "Expected source picker to remain visible.")

        let recordButton = app.buttons[UITestIDs.Panel.recordButton]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 10), "Expected regular record button to remain available.")
        recordButton.click()

        let stopButton = app.buttons[UITestIDs.Panel.stopButton]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 15), "Expected recording to start from the manual record button.")

        postSimulatedAutoPrompt(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            meetingLabel: "Google Meet in Safari",
            active: false
        )
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertTrue(stopButton.exists, "Expected manual recording to keep running when detected meeting audio ends.")

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "auto-prompt-manual-record"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDetectedMeetingSuggestionAutoStopsWhenAudioEnds() throws {
        let app = launchRecappiApp(
            authToken: "invalid-test-token",
            simulatedAutoPromptApp: (bundleID: "com.google.Chrome", name: "Google Chrome"),
            simulatedAutoPromptMeetingLabel: "Google Meet in Chrome",
            detectedMeetingAutoStopGraceSeconds: 0.1
        )

        let suggestion = uiElement(app, id: UITestIDs.Panel.recordingSuggestion)
        XCTAssertTrue(suggestion.waitForExistence(timeout: 15), "Expected auto-prompt suggestion banner.")
        suggestion.click()

        let stopButton = app.buttons[UITestIDs.Panel.stopButton]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 15), "Expected suggested app recording to start.")

        postSimulatedAutoPrompt(
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            meetingLabel: "Google Meet in Chrome",
            active: false
        )

        XCTAssertTrue(
            waitForNonExistence(of: stopButton, timeout: 15),
            "Expected suggested meeting recording to auto-stop after meeting audio ended."
        )
    }

    func testCloudCenterSignedOutLaunchSmoke() throws {
        let app = launchRecappiApp(authToken: "", openCloudWindowOnLaunch: true)

        let cloudWindow = uiElement(app, id: UITestIDs.Cloud.window)
        XCTAssertTrue(cloudWindow.waitForExistence(timeout: 15), "Expected Recappi Cloud window to open in UI-test mode.")

        let authStatus = uiElement(app, id: UITestIDs.Cloud.authStatus)
        XCTAssertTrue(authStatus.waitForExistence(timeout: 10), "Expected Cloud auth status chip.")

        XCTAssertTrue(
            app.buttons[UITestIDs.Cloud.signInGoogleButton].waitForExistence(timeout: 10),
            "Expected Google sign-in CTA in signed-out Cloud Center."
        )
        XCTAssertTrue(
            app.buttons[UITestIDs.Cloud.signInGitHubButton].waitForExistence(timeout: 10),
            "Expected GitHub sign-in CTA in signed-out Cloud Center."
        )

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "cloud-center-signed-out"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCloudCenterLoadsLiveRecordingsWithSeededBearer() throws {
        guard let authToken = UITestPaths.liveAuthTokenValue, !authToken.isEmpty else {
            throw XCTSkip("Set RECAPPI_TEST_AUTH_TOKEN to run the live Cloud Center library smoke.")
        }

        let app = launchRecappiApp(authToken: authToken, openCloudWindowOnLaunch: true)

        let cloudWindow = uiElement(app, id: UITestIDs.Cloud.window)
        XCTAssertTrue(cloudWindow.waitForExistence(timeout: 15), "Expected Recappi Cloud window to open.")

        let recordingsList = uiElement(app, id: UITestIDs.Cloud.recordingsList)
        XCTAssertTrue(
            recordingsList.waitForExistence(timeout: 30),
            "Expected live cloud recordings list to load without decoding errors."
        )
        XCTAssertTrue(
            uiElement(app, id: UITestIDs.Cloud.billingStatus).waitForExistence(timeout: 10),
            "Expected Cloud Center to show billing plan and limits for a signed-in account."
        )
        let infoButton = app.buttons[UITestIDs.Cloud.recordingInfoButton]
        XCTAssertTrue(infoButton.waitForExistence(timeout: 10), "Expected recording info control in the compact detail header.")
        XCTAssertTrue(infoButton.isHittable, "Expected recording info control to be visible and hittable, not clipped under the titlebar.")
        let actionsMenu = app.buttons[UITestIDs.Cloud.moreActionsButton]
        XCTAssertTrue(actionsMenu.waitForExistence(timeout: 10), "Expected More actions menu in the compact detail header.")
        XCTAssertTrue(actionsMenu.isHittable, "Expected More actions menu to be visible and hittable, not clipped below the window.")
        actionsMenu.click()
        XCTAssertTrue(
            app.menuItems["Download audio"].waitForExistence(timeout: 5) || app.menuItems["Reveal audio"].waitForExistence(timeout: 1),
            "Expected audio export action inside More actions menu."
        )
        XCTAssertTrue(
            app.menuItems["Delete recording"].waitForExistence(timeout: 5),
            "Expected delete action inside More actions menu."
        )
        app.typeKey(.escape, modifierFlags: [])

        let initialWindowHeight = cloudWindow.frame.height
        let transcriptText = uiElement(app, id: UITestIDs.Cloud.transcriptText)
        if !transcriptText.waitForExistence(timeout: 5) {
            let loadTranscriptButton = app.buttons[UITestIDs.Cloud.loadTranscriptButton]
            XCTAssertTrue(
                loadTranscriptButton.waitForExistence(timeout: 10),
                "Expected transcript text or a loading affordance for recordings without a cached transcript."
            )
            XCTAssertTrue(loadTranscriptButton.isHittable, "Expected Load transcript button to be visible before loading.")
            loadTranscriptButton.click()
            XCTAssertTrue(
                transcriptText.waitForExistence(timeout: 10),
                "Expected live cloud transcript text to load for the selected ready recording."
            )
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(
            cloudWindow.frame.height,
            initialWindowHeight,
            accuracy: 1,
            "Expected Cloud Center window height to stay stable while transcript loading starts."
        )

        let rowPredicate = NSPredicate(format: "identifier BEGINSWITH %@", UITestIDs.Cloud.recordingRowPrefix)
        let rows = recordingsList.descendants(matching: .any).matching(rowPredicate)
        XCTAssertGreaterThanOrEqual(rows.count, 2, "Expected enough live recordings to exercise selection layout stability.")
        rows.element(boundBy: 1).click()
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 10), "Expected detail actions to remain visible after changing selection.")
        XCTAssertEqual(
            cloudWindow.frame.height,
            initialWindowHeight,
            accuracy: 1,
            "Expected Cloud Center window height to stay stable while switching recordings."
        )

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "cloud-center-live-recordings"
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
        XCTAssertTrue(meetingPrompt.waitForExistence(timeout: 5), "Expected hidden auto-prompt to explain that a Safari meeting was detected.")
        let promptText = [meetingPrompt.label, meetingPrompt.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            promptText.localizedCaseInsensitiveContains("Google Meet detected in Safari"),
            "Expected meeting prompt copy, got: \(promptText)"
        )

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "hidden-auto-prompt-preselects-app"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHiddenPanelAutoPromptSelectsArcMeeting() throws {
        let app = launchRecappiApp(authToken: "")
        hidePanel(in: app)

        postSimulatedAutoPrompt(
            bundleID: "company.thebrowser.Browser",
            appName: "Arc",
            meetingLabel: "Google Meet in Arc",
            active: true
        )

        let sourcePicker = uiElement(app, id: UITestIDs.Panel.audioSourcePicker)
        XCTAssertTrue(sourcePicker.waitForExistence(timeout: 15), "Expected panel to reappear for an Arc meeting.")
        let sourceText = [sourcePicker.label, sourcePicker.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            sourceText.localizedCaseInsensitiveContains("Arc"),
            "Expected hidden auto-prompt to preselect Arc, got: \(sourceText)"
        )

        let meetingPrompt = uiElement(app, id: UITestIDs.Panel.meetingPrompt)
        XCTAssertTrue(meetingPrompt.waitForExistence(timeout: 5), "Expected hidden auto-prompt to explain that an Arc meeting was detected.")
        let promptText = [meetingPrompt.label, meetingPrompt.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            promptText.localizedCaseInsensitiveContains("Google Meet detected in Arc"),
            "Expected Arc meeting prompt copy, got: \(promptText)"
        )
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
            suggestionText.localizedCaseInsensitiveContains("Google Meet detected in Chrome"),
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
