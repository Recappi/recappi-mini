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
        startFixtureRecording(in: app)

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

    func testLiveCaptionsOpenCurrentMeetingCloudPanel() throws {
        let longCaption = (1...220)
            .map { "Short realtime chunk \($0) keeps flowing" }
            .joined(separator: " ") + " Final bottom phrase should remain visible."

        let app = launchRecappiApp(
            authToken: "invalid-test-token",
            simulatedLiveCaptionText: longCaption
        )

        startFixtureRecording(in: app)

        let panelCaptionsButton = app.buttons[UITestIDs.Panel.liveCaptionsButton]
        XCTAssertTrue(
            panelCaptionsButton.waitForExistence(timeout: 10),
            "Expected recording panel to expose a direct live captions reopen button."
        )
        let cloudButton = app.buttons[UITestIDs.Panel.cloudButton]
        XCTAssertFalse(
            cloudButton.waitForExistence(timeout: 1),
            "Recording panel should keep Cloud chrome out of the compact control row."
        )

        XCTAssertFalse(
            uiElement(app, id: UITestIDs.Cloud.window).waitForExistence(timeout: 2),
            "Recording should not open the full Cloud window automatically."
        )

        let currentMeetingPanel = uiElement(app, id: UITestIDs.Cloud.currentMeetingPanel)
        XCTAssertTrue(currentMeetingPanel.waitForExistence(timeout: 15), "Expected live captions to open in an independent Cloud floating panel.")

        let caption = uiElement(app, id: UITestIDs.Cloud.currentMeetingCaption)
        XCTAssertTrue(caption.waitForExistence(timeout: 10), "Expected current-meeting captions in Cloud.")
        let captionViewport = app.scrollViews[UITestIDs.Cloud.currentMeetingCaptionViewport]
        XCTAssertTrue(captionViewport.waitForExistence(timeout: 10), "Expected current-meeting caption viewport.")
        XCTAssertGreaterThanOrEqual(
            captionViewport.frame.width,
            450,
            "Expected live captions to use the expanded panel width, not collapse into a narrow column."
        )
        XCTAssertGreaterThanOrEqual(
            caption.frame.width,
            430,
            "Expected live caption text to wrap at the expanded viewport width."
        )
        XCTAssertGreaterThanOrEqual(
            captionViewport.frame.height,
            96,
            "Expected live captions to keep a readable expanded viewport while staying compact enough to feel like an overlay."
        )
        XCTAssertGreaterThan(
            caption.frame.height,
            captionViewport.frame.height + 24,
            "Expected long live captions to overflow the viewport so the panel can scroll."
        )
        XCTAssertTrue(captionViewport.isHittable, "Expected the whole live caption viewport to accept scroll gestures.")
        let viewportGeometry = """
        captionViewport.frame=\(captionViewport.frame)
        caption.frame=\(caption.frame)
        """
        let viewportAttachment = XCTAttachment(string: viewportGeometry)
        viewportAttachment.name = "live-caption-viewport-geometry"
        viewportAttachment.lifetime = .keepAlways
        add(viewportAttachment)
        let bilingualToggle = uiElement(app, id: UITestIDs.Cloud.currentMeetingBilingualToggle)
        XCTAssertFalse(
            bilingualToggle.waitForExistence(timeout: 1),
            "Recording-time translation controls should stay out of the Live Caption panel."
        )
        let captionText = [caption.label, caption.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            captionText.localizedCaseInsensitiveContains("Final bottom phrase"),
            "Expected simulated caption text in Cloud, got: \(captionText)"
        )
        XCTAssertFalse(
            captionText.contains("\nShort realtime chunk"),
            "Short upstream chunks should flow as wrapped text instead of one forced line per item."
        )
        XCTAssertFalse(
            uiElement(app, id: UITestIDs.Panel.liveCaptionText).exists,
            "Live captions should not render inside the tiny recording panel."
        )

        let closeCaptionPanel = uiElement(app, id: UITestIDs.Cloud.currentMeetingCaptionCloseButton)
        XCTAssertTrue(revealLiveCaptionChrome(in: app), "Expected live-caption chrome to reveal on hover.")
        XCTAssertTrue(closeCaptionPanel.waitForExistence(timeout: 10), "Expected a close control on the floating Live Caption panel.")
        closeCaptionPanel.click()
        XCTAssertTrue(
            waitForNonExistence(of: currentMeetingPanel, timeout: 5),
            "Expected the floating Live Caption panel to close independently from the Cloud recording list."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(2.2))
        XCTAssertFalse(
            currentMeetingPanel.exists,
            "A dismissed Live Caption panel should stay hidden for the current recording session."
        )

        panelCaptionsButton.click()
        XCTAssertTrue(
            currentMeetingPanel.waitForExistence(timeout: 5),
            "Expected the recording-panel captions button to reopen the floating Live Caption panel."
        )
        XCTAssertTrue(revealLiveCaptionChrome(in: app), "Expected live-caption chrome to reveal after reopening.")

        let modeButton = app.buttons[UITestIDs.Cloud.currentMeetingPanelModeButton]
        XCTAssertTrue(modeButton.waitForExistence(timeout: 10), "Expected a compact/expanded mode control.")
        modeButton.hover()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        modeButton.click()
        let compactCaption = uiElement(app, id: UITestIDs.Cloud.currentMeetingCaption)
        XCTAssertTrue(compactCaption.waitForExistence(timeout: 5), "Expected compact caption text.")
        let compactText = [compactCaption.label, compactCaption.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            compactText.localizedCaseInsensitiveContains("Final bottom phrase"),
            "Expected compact mode to show the latest flowing caption phrase, got: \(compactText)"
        )
        XCTAssertGreaterThan(
            compactText.count,
            45,
            "Compact mode should show recent flowing context, not one tiny upstream chunk."
        )
        XCTAssertFalse(
            compactText.contains("...") || compactText.contains("…"),
            "Compact live captions should not render a truncated history string."
        )

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "live-caption-current-meeting-cloud-panel"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testManualLiveCaptionReconnectDoesNotInterruptOrClearCaptions() throws {
        let liveCaption = "Reconnect smoke caption should stay visible after a manual reconnect click."
        let app = launchRecappiApp(
            authToken: "invalid-test-token",
            simulatedLiveCaptionText: liveCaption,
            simulatedLiveCaptionErrorMessage: "Live caption connection lost. Click to reconnect."
        )

        startFixtureRecording(in: app)

        let currentMeetingPanel = uiElement(app, id: UITestIDs.Cloud.currentMeetingPanel)
        XCTAssertTrue(currentMeetingPanel.waitForExistence(timeout: 15), "Expected live captions panel.")

        let caption = uiElement(app, id: UITestIDs.Cloud.currentMeetingCaption)
        XCTAssertTrue(caption.waitForExistence(timeout: 10), "Expected current-meeting captions in Cloud.")
        let captionText = [caption.label, caption.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(captionText.localizedCaseInsensitiveContains("Reconnect smoke caption"))

        XCTAssertTrue(revealLiveCaptionChrome(in: app), "Expected live-caption chrome to reveal for reconnect.")

        let reconnectButton = app.buttons[UITestIDs.Cloud.currentMeetingCaptionReconnectButton]
        XCTAssertTrue(reconnectButton.waitForExistence(timeout: 5), "Expected a clickable live-caption warning control.")
        XCTAssertTrue(
            (reconnectButton.value as? String ?? "")
                .localizedCaseInsensitiveContains("connection lost"),
            "Expected warning control to expose the error text."
        )
        reconnectButton.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertFalse(
            app.buttons["OK"].waitForExistence(timeout: 0.5),
            "Manual reconnect should not show a blocking NSAlert confirmation button."
        )
        let captionTextAfterReconnect = [caption.label, caption.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        XCTAssertTrue(
            captionTextAfterReconnect.localizedCaseInsensitiveContains("Reconnect smoke caption"),
            "Manual reconnect should preserve existing live captions, got: \(captionTextAfterReconnect)"
        )
    }

    func testRealtimeWebSocketDisconnectReconnectsAndPreservesCaptions() throws {
        let backendURLOverridePath = "/tmp/recappi-mini-fake-realtime-backend-url"
        let fileBackendURL = try? String(contentsOfFile: backendURLOverridePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let backendURL = ProcessInfo.processInfo.environment["RECAPPI_TEST_FAKE_REALTIME_BACKEND_URL"]
            ?? fileBackendURL
        guard let backendURL,
              !backendURL.isEmpty else {
            throw XCTSkip("Run scripts/run-realtime-ws-ui-test.sh to provide a real fake backend URL.")
        }

        let app = launchRecappiApp(
            authToken: "test_backend_token",
            backendURL: backendURL,
            useBackendRealtimeLiveCaptions: true,
            openCloudWindowOnLaunch: false
        )

        startFixtureRecording(in: app)

        let currentMeetingPanel = uiElement(app, id: UITestIDs.Cloud.currentMeetingPanel)
        XCTAssertTrue(currentMeetingPanel.waitForExistence(timeout: 15), "Expected live captions panel.")

        let caption = uiElement(app, id: UITestIDs.Cloud.currentMeetingCaption)
        XCTAssertTrue(
            waitForText(in: caption, containing: "Caption before websocket disconnect", timeout: 10),
            "Expected the fake backend's first transcript before it closes the first WebSocket."
        )
        XCTAssertTrue(
            waitForText(in: caption, containing: "Caption after websocket reconnect", timeout: 20),
            "Expected automatic reconnect to attach to a second real WebSocket and receive more transcript."
        )

        let captionTextAfterReconnect = elementText(caption)
        XCTAssertTrue(
            captionTextAfterReconnect.localizedCaseInsensitiveContains("Caption before websocket disconnect"),
            "Automatic reconnect should preserve caption history, got: \(captionTextAfterReconnect)"
        )
        XCTAssertFalse(
            app.buttons["OK"].waitForExistence(timeout: 0.5),
            "A real WebSocket disconnect should not show a blocking NSAlert."
        )
    }

    func testLiveCaptionsBilingualPanelShowsIndependentStreams() throws {
        let sourceText = "If you have a team, pay attention. It is a very important thing. You should pay them too"
        let translationText = "如果你有一个团队，要多关注他们。这是一件很重要的事情。你也应该付钱给他们"

        let app = launchRecappiApp(
            authToken: "invalid-test-token",
            simulatedLiveCaptionText: sourceText,
            simulatedLiveCaptionTranslationText: translationText
        )

        startFixtureRecording(in: app, showTranslation: true)

        let captionViewport = app.scrollViews[UITestIDs.Cloud.currentMeetingCaptionViewport]
        XCTAssertTrue(captionViewport.waitForExistence(timeout: 10), "Expected bilingual source caption viewport.")
        let translationViewport = app.scrollViews[UITestIDs.Cloud.currentMeetingTranslationViewport]
        XCTAssertTrue(translationViewport.waitForExistence(timeout: 10), "Expected bilingual translation viewport.")

        let caption = uiElement(app, id: UITestIDs.Cloud.currentMeetingCaption)
        let captionText = [caption.label, caption.value as? String]
            .compactMap { $0 }
            .joined(separator: "\n")
        XCTAssertTrue(captionText.contains("If you have a team, pay attention."))
        XCTAssertTrue(captionText.contains("It is a very important thing."))
        XCTAssertTrue(captionText.contains("You should pay them too"))
        let translation = uiElement(app, id: UITestIDs.Cloud.currentMeetingTranslation)
        let renderedTranslationText = [translation.label, translation.value as? String]
            .compactMap { $0 }
            .joined(separator: "\n")
        XCTAssertTrue(renderedTranslationText.contains("如果你有一个团队，要多关注他们。"))
        XCTAssertTrue(renderedTranslationText.contains("这是一件很重要的事情。"))
        XCTAssertTrue(renderedTranslationText.contains("你也应该付钱给他们"))

        XCTAssertTrue(revealLiveCaptionChrome(in: app), "Expected live-caption stream controls to reveal on hover.")

        let captionToggle = app.buttons[UITestIDs.Cloud.currentMeetingCaptionToggleButton]
        let translationToggle = app.buttons[UITestIDs.Cloud.currentMeetingTranslationToggleButton]
        let bilingualToggle = app.buttons[UITestIDs.Cloud.currentMeetingBilingualToggle]
        XCTAssertTrue(captionToggle.waitForExistence(timeout: 5), "Expected caption stream toggle.")
        XCTAssertTrue(translationToggle.waitForExistence(timeout: 5), "Expected translation stream toggle.")
        XCTAssertFalse(bilingualToggle.exists, "Bilingual mode is represented by both two-key stream toggles being on.")

        XCTAssertTrue(waitUntilEnabled(translationToggle, timeout: 5), "Expected translation stream toggle to be enabled while both streams are visible.")
        translationToggle.click()
        XCTAssertTrue(captionViewport.exists, "Caption stream should remain visible after hiding translation.")
        XCTAssertTrue(waitUntilEnabled(translationToggle, timeout: 5), "Expected translation stream toggle to re-enable translation.")
        translationToggle.click()
        XCTAssertTrue(captionViewport.waitForExistence(timeout: 5), "Expected paired bilingual stream to return.")
        XCTAssertTrue(translationViewport.waitForExistence(timeout: 5), "Expected translation stream to return.")
        XCTAssertTrue(waitUntilEnabled(captionToggle, timeout: 5), "Expected caption stream toggle to be enabled while both streams are visible.")
        captionToggle.click()
        XCTAssertTrue(translationViewport.exists, "Translation stream should remain visible after hiding captions.")
    }

    func testLiveCaptionsExpandedPanelFitsMediumCaptionGeometry() throws {
        let mediumCaption = """
        这一期我们声港的地方我要去一个特别的很多观众都知道，过去几年瞬间消息主要关注的一个方向就是医药健康领域经常提到虽然创新那种研发还是美国主导的。但药品原料粉末中国早就占据了大头。
        """

        let app = launchRecappiApp(
            authToken: "invalid-test-token",
            simulatedLiveCaptionText: mediumCaption
        )

        startFixtureRecording(in: app)

        let currentMeetingPanel = uiElement(app, id: UITestIDs.Cloud.currentMeetingPanel)
        XCTAssertTrue(currentMeetingPanel.waitForExistence(timeout: 15), "Expected live captions panel.")

        let captionWorkspace = uiElement(app, id: UITestIDs.Cloud.currentMeetingCaptionWorkspace)
        XCTAssertTrue(captionWorkspace.waitForExistence(timeout: 10), "Expected live captions workspace.")

        let captionViewport = app.scrollViews[UITestIDs.Cloud.currentMeetingCaptionViewport]
        XCTAssertTrue(captionViewport.waitForExistence(timeout: 10), "Expected caption viewport.")

        let caption = uiElement(app, id: UITestIDs.Cloud.currentMeetingCaption)
        XCTAssertTrue(caption.waitForExistence(timeout: 10), "Expected caption text.")

        let geometry = """
        panel.frame=\(currentMeetingPanel.frame)
        captionWorkspace.frame=\(captionWorkspace.frame)
        captionViewport.frame=\(captionViewport.frame)
        caption.frame=\(caption.frame)
        """
        let attachment = XCTAttachment(string: geometry)
        attachment.name = "live-caption-medium-geometry"
        attachment.lifetime = .keepAlways
        add(attachment)

        let leftGutter = captionViewport.frame.minX - currentMeetingPanel.frame.minX
        let rightGutter = currentMeetingPanel.frame.maxX - captionViewport.frame.maxX
        XCTAssertLessThanOrEqual(
            abs(leftGutter - rightGutter),
            8,
            "Expanded captions should keep left/right gutters balanced, got left=\(leftGutter) right=\(rightGutter)."
        )
        XCTAssertLessThanOrEqual(
            rightGutter,
            32,
            "Expanded captions should not leave a large unused right gutter."
        )
        XCTAssertGreaterThanOrEqual(
            captionViewport.frame.height,
            captionWorkspace.frame.height - 92,
            "Expanded captions should fill the caption workspace below the header instead of using a fixed short viewport."
        )
    }

    func testLiveCaptionsCompactModeShowsCoherentLatestSentence() throws {
        let liveCaption = """
        这个就是典型的例子。确实能够活起来有它的暴力人体细胞题里面有一层内膜。细胞里有食物的能量跟水力发电
        """

        let app = launchRecappiApp(
            authToken: "invalid-test-token",
            simulatedLiveCaptionText: liveCaption
        )

        startFixtureRecording(in: app)

        let currentMeetingPanel = uiElement(app, id: UITestIDs.Cloud.currentMeetingPanel)
        XCTAssertTrue(currentMeetingPanel.waitForExistence(timeout: 15), "Expected live captions panel.")
        XCTAssertTrue(revealLiveCaptionChrome(in: app), "Expected live-caption mode control to reveal on hover.")

        let modeButton = app.buttons[UITestIDs.Cloud.currentMeetingPanelModeButton]
        XCTAssertTrue(modeButton.waitForExistence(timeout: 10), "Expected a compact/expanded mode control.")
        modeButton.hover()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        modeButton.click()

        let compactCaption = uiElement(app, id: UITestIDs.Cloud.currentMeetingCaption)
        XCTAssertTrue(compactCaption.waitForExistence(timeout: 5), "Expected compact caption text.")
        let compactModeButton = app.buttons[UITestIDs.Cloud.currentMeetingPanelModeButton]
        let compactElapsedTime = app.staticTexts[UITestIDs.Cloud.currentMeetingCaptionElapsedTime]
        compactCaption.hover()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(compactModeButton.waitForExistence(timeout: 5), "Expected compact mode control to appear on hover.")
        XCTAssertTrue(compactElapsedTime.waitForExistence(timeout: 5), "Expected compact elapsed time to appear on hover.")
        let compactPanel = uiElement(app, id: UITestIDs.Cloud.currentMeetingPanel)
        let compactGeometry = """
        compactPanel.frame=\(compactPanel.frame)
        compactCaption.frame=\(compactCaption.frame)
        compactElapsedTime.frame=\(compactElapsedTime.frame)
        compactModeButton.frame=\(compactModeButton.frame)
        """
        let attachment = XCTAttachment(string: compactGeometry)
        attachment.name = "live-caption-compact-geometry"
        attachment.lifetime = .keepAlways
        add(attachment)
        let compactText = [compactCaption.label, compactCaption.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Compact mode pre-truncates the caption to a CJK budget of 46
        // characters via `String.suffix`, so the LATEST tail is the only
        // content guaranteed to be visible. The fixture above is 49 CJK
        // chars, intentionally pushed past the budget so we exercise the
        // suffix cut. We assert (a) the tail is preserved verbatim, and
        // (b) the cut never inserts an ellipsis indicator (separately
        // covered below). We do NOT assert the earliest sentence is
        // visible — that would be incompatible with the budget-driven
        // tail policy.
        XCTAssertTrue(
            compactText.contains("细胞里有食物的能量跟水力发电"),
            "Compact mode should still preserve the newest caption tail, got: \(compactText)"
        )
        XCTAssertFalse(
            compactText.contains("...") || compactText.contains("…"),
            "Compact live captions should not rely on visual ellipsis for the newest content."
        )
        XCTAssertFalse(
            compactText.contains("\n"),
            "Compact mode should render a continuous paragraph and let the two-line view wrap naturally."
        )
        // The right cluster contains: red-dot (6pt) → spacing (6pt) →
        // elapsed-time text (~30pt) → spacing (6pt) → mode button (22pt)
        // → close button. So between caption.maxX and modeButton.minX
        // there's ~58pt of cluster width that has nothing to do with
        // the caption "consuming the middle lane". Measure against
        // `compactElapsedTime.minX` instead — that's the first AX-tagged
        // element after the (untagged) red-dot, so the gap reflects the
        // actual lane fill, not unrelated cluster offsets.
        XCTAssertLessThanOrEqual(
            compactElapsedTime.frame.minX - compactCaption.frame.maxX,
            32,
            "Compact caption should consume the middle lane instead of leaving a large right-side gap before the elapsed-time chrome."
        )
        XCTAssertLessThanOrEqual(
            abs(compactCaption.frame.midY - compactModeButton.frame.midY),
            8,
            "Compact caption text and controls should share a visual center line."
        )
        XCTAssertLessThanOrEqual(
            abs(compactCaption.frame.midY - compactElapsedTime.frame.midY),
            8,
            "Compact caption text and elapsed time should share a visual center line."
        )
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
        completeRecordingPreflight(in: app)

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
        let downloadButton = app.buttons[UITestIDs.Cloud.downloadAudioButton]
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

    func testCloudSelectionStaysResponsiveDuringLocalRecordingWithSeededBearer() throws {
        guard let authToken = UITestPaths.liveAuthTokenValue, !authToken.isEmpty else {
            throw XCTSkip("Set RECAPPI_TEST_AUTH_TOKEN to run the live Cloud selection while recording smoke.")
        }

        let app = launchRecappiApp(authToken: authToken)

        startFixtureRecording(in: app)

        let cloudButton = app.buttons[UITestIDs.Panel.cloudButton]
        XCTAssertTrue(cloudButton.waitForExistence(timeout: 10), "Expected recording panel to keep a Cloud entry point.")
        cloudButton.click()

        let cloudWindow = uiElement(app, id: UITestIDs.Cloud.window)
        XCTAssertTrue(cloudWindow.waitForExistence(timeout: 15), "Expected Cloud window to open when requested during recording.")

        let recordingsList = uiElement(app, id: UITestIDs.Cloud.recordingsList)
        XCTAssertTrue(recordingsList.waitForExistence(timeout: 30), "Expected Cloud recordings list while local recording is active.")

        let rowPredicate = NSPredicate(format: "identifier BEGINSWITH %@", UITestIDs.Cloud.recordingRowPrefix)
        let rows = recordingsList.descendants(matching: .any).matching(rowPredicate)
        XCTAssertGreaterThanOrEqual(rows.count, 2, "Expected at least two Cloud recordings to switch between.")

        for index in [1, 0, 1] {
            rows.element(boundBy: index).click()
            XCTAssertTrue(
                app.buttons[UITestIDs.Cloud.moreActionsButton].waitForExistence(timeout: 5),
                "Expected Cloud detail actions to stay responsive after selecting row \(index) during local recording."
            )
        }

        XCTAssertTrue(
            app.buttons[UITestIDs.Panel.stopButton].waitForExistence(timeout: 5),
            "Expected the active local recording controls to remain responsive after Cloud selection changes."
        )

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "cloud-selection-during-local-recording"
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
