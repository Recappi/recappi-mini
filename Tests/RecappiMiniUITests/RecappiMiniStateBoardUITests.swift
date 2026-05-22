import AppKit
import ImageIO
import XCTest

@MainActor
final class RecappiMiniStateBoardUITests: XCTestCase {
    private let outputDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/RecappiMiniStateBoard", isDirectory: true)

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureStateBoardV0() throws {
        try prepareOutputDirectory()
        try captureRecordingPanelStates()
        try captureLiveCaptionStates()
        try captureCloudDetailStates()
        try captureSettingsStates()
        try captureOnboardingStates()
    }

    func testCloudTranscriptTextClickSelectsSegment() throws {
        try prepareOutputDirectory()

        let app = launchStateBoardApp(authToken: "state-board-token", openCloudWindowOnLaunch: true)

        let cloudWindow = uiElement(app, id: UITestIDs.Cloud.window)
        XCTAssertTrue(cloudWindow.waitForExistence(timeout: 15), "Expected Cloud window.")

        let transcript = app.buttons[UITestIDs.Cloud.jumpToTranscriptButton]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "Expected Transcription tab button.")
        transcript.click()

        let firstSegmentText = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", UITestIDs.Cloud.transcriptSegmentTextPrefix))
            .firstMatch
        XCTAssertTrue(firstSegmentText.waitForExistence(timeout: 5), "Expected transcript segment text.")

        firstSegmentText.click()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !firstSegmentText.isSelected {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(firstSegmentText.isSelected, "Clicking the transcript text body should select/jump to that segment.")
    }

    func testCloudTranscriptSpeakerNameOpensRenamePopover() throws {
        try prepareOutputDirectory()

        let app = launchStateBoardApp(authToken: "state-board-token", openCloudWindowOnLaunch: true)

        let cloudWindow = uiElement(app, id: UITestIDs.Cloud.window)
        XCTAssertTrue(cloudWindow.waitForExistence(timeout: 15), "Expected Cloud window.")

        let transcript = app.buttons[UITestIDs.Cloud.jumpToTranscriptButton]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "Expected Transcription tab button.")
        transcript.click()

        let speakerButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", UITestIDs.Cloud.speakerNameButtonPrefix)
        ).firstMatch
        XCTAssertTrue(speakerButton.waitForExistence(timeout: 5), "Expected transcript speaker name to be a clickable rename entry.")

        speakerButton.click()

        let renamePopover = uiElement(app, id: UITestIDs.Cloud.speakerRenamePopover)
        XCTAssertTrue(renamePopover.waitForExistence(timeout: 5), "Expected clicking speaker name to open rename popover.")
    }

    private func captureRecordingPanelStates() throws {
        let suggestionApp = launchStateBoardApp(
            simulatedAutoPromptApp: (bundleID: "com.apple.Safari", name: "Safari"),
            simulatedAutoPromptMeetingLabel: "Google Meet",
            detectedMeetingAutoStopGraceSeconds: 99
        )
        XCTAssertTrue(suggestionApp.buttons[UITestIDs.Panel.recordButton].waitForExistence(timeout: 15), "Expected Record button.")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        try captureRecordingPanel(in: suggestionApp, named: "recording_idle_with-meeting-suggestion")

        let app = launchStateBoardApp()

        XCTAssertTrue(app.buttons[UITestIDs.Panel.recordButton].waitForExistence(timeout: 15), "Expected Record button.")
        try captureRecordingPanel(in: app, named: "recording_idle_xcuitest", overwrite: false)

        let options = app.buttons[UITestIDs.Panel.recordingOptionsButton]
        XCTAssertTrue(options.waitForExistence(timeout: 15), "Expected Options button.")
        options.click()
        let optionsPopover = uiElement(app, id: UITestIDs.Panel.recordingOptionsPopover)
        try capture(optionsPopover, named: "recording_options_default")
        let optionMic = uiElement(app, id: UITestIDs.Panel.microphoneIncludeButton)
        XCTAssertTrue(optionMic.waitForExistence(timeout: 5), "Expected Options microphone toggle.")
        optionMic.click()
        app.typeKey(.escape, modifierFlags: [])

        startFixtureRecording(in: app)
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        try captureRecordingPanel(in: app, named: "recording_recording_micOff")

        let waveform = uiElement(app, id: UITestIDs.Panel.waveformToggle)
        XCTAssertTrue(waveform.waitForExistence(timeout: 5), "Expected waveform toggle.")
        waveform.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        try captureRecordingPanel(in: app, named: "recording_waveformHistory")

        let mic = app.buttons[UITestIDs.Panel.microphoneIncludeButton]
        XCTAssertTrue(mic.waitForExistence(timeout: 5), "Expected microphone toggle.")
        mic.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        try captureRecordingPanel(in: app, named: "recording_recording_micOn")

        let more = uiElement(app, id: UITestIDs.Panel.recordingMoreButton)
        XCTAssertTrue(more.waitForExistence(timeout: 5), "Expected recording More button.")
        more.click()
        let discardMenuItem = app.menuItems[UITestIDs.Panel.discardMenuItem]
        XCTAssertTrue(discardMenuItem.waitForExistence(timeout: 5), "Expected discard menu item.")
        discardMenuItem.click()
        let discardConfirmButton = app.buttons[UITestIDs.Panel.discardButton]
        XCTAssertTrue(discardConfirmButton.waitForExistence(timeout: 5), "Expected discard confirmation popover.")
        try captureScreenRegion(
            around: panelBoundsElements(in: app) + [discardConfirmButton],
            named: "recording_discard_confirm",
            horizontalPadding: 80,
            verticalPadding: 80
        )
        app.typeKey(.escape, modifierFlags: [])

        let stop = app.buttons[UITestIDs.Panel.stopButton]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Expected stop button.")
        stop.click()
        let processing = uiElement(app, id: UITestIDs.Panel.processingTitle)
        if processing.waitForExistence(timeout: 5) {
            try captureRecordingPanel(in: app, named: "recording_processing")
        }

        try captureRecordingTerminalStates()
    }

    private func captureRecordingTerminalStates() throws {
        try captureRecordingFixtureState(
            "processing",
            expectedID: UITestIDs.Panel.processingTitle,
            named: "recording_processing"
        )
        try captureRecordingFixtureState(
            "done-transcribe-pending",
            expectedID: UITestIDs.Panel.doneTitle,
            named: "recording_done_transcribePending"
        )
        try captureRecordingFixtureState(
            "done-ready",
            expectedID: UITestIDs.Panel.doneTitle,
            named: "recording_done_readyOrTranscript"
        )
        try captureRecordingFixtureState(
            "error",
            expectedID: UITestIDs.Panel.errorTitle,
            named: "recording_error"
        )
    }

    private func captureRecordingFixtureState(_ state: String, expectedID: String, named name: String) throws {
        let app = launchStateBoardApp(recordingPanelState: state)
        let expected = uiElement(app, id: expectedID)
        XCTAssertTrue(expected.waitForExistence(timeout: 15), "Expected \(expectedID) for \(name).")
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        try captureScreenRegion(around: panelBoundsElements(in: app), named: name, horizontalPadding: 190)
    }

    private func captureLiveCaptionStates() throws {
        let sourceText = "Design board caption one. Design board caption two keeps enough text visible for layout review."
        let app = launchStateBoardApp(
            liveCaptionText: sourceText
        )
        startFixtureRecording(in: app)

        let panel = uiElement(app, id: UITestIDs.Cloud.currentMeetingPanel)
        XCTAssertTrue(panel.waitForExistence(timeout: 15), "Expected live caption panel.")
        try capture(panel, named: "liveCaptions_expanded")

        XCTAssertTrue(revealLiveCaptionChrome(in: app, timeout: 10), "Expected live caption mode button.")
        let mode = app.buttons[UITestIDs.Cloud.currentMeetingPanelModeButton]
        XCTAssertTrue(mode.exists, "Expected live caption mode button.")
        mode.hover()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        mode.click()
        try capture(panel, named: "liveCaptions_compact")

        let bilingualApp = launchStateBoardApp(
            liveCaptionText: "We should compare the caption and translation layouts before changing the panel.",
            liveCaptionTranslationText: "在改面板之前，我们应该先比较字幕和翻译的排版。"
        )
        startFixtureRecording(in: bilingualApp)
        let bilingualPanel = uiElement(bilingualApp, id: UITestIDs.Cloud.currentMeetingPanel)
        XCTAssertTrue(bilingualPanel.waitForExistence(timeout: 15), "Expected bilingual live caption panel.")
        try capture(bilingualPanel, named: "liveCaptions_bilingual")
    }

    private func captureCloudDetailStates() throws {
        let app = launchStateBoardApp(authToken: "state-board-token", openCloudWindowOnLaunch: true)

        let cloudWindow = uiElement(app, id: UITestIDs.Cloud.window)
        XCTAssertTrue(cloudWindow.waitForExistence(timeout: 15), "Expected Cloud window.")
        let summary = app.buttons[UITestIDs.Cloud.jumpToSummaryButton]
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "Expected Summary tab button.")
        summary.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try capture(largestWindow(in: app), named: "cloud_summary")
        let summaryBadge = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", UITestIDs.Cloud.summarySourceBadgePrefix)
        ).firstMatch
        if summaryBadge.waitForExistence(timeout: 5) {
            summaryBadge.click()
            let sourcePopover = uiElement(app, id: UITestIDs.Cloud.summarySourcePopover)
            XCTAssertTrue(sourcePopover.waitForExistence(timeout: 5), "Expected summary source popover.")
            try captureScreenRegion(
                around: [largestWindow(in: app), sourcePopover],
                named: "cloud_summary_source_popover",
                horizontalPadding: 24,
                verticalPadding: 24
            )
            app.typeKey(.escape, modifierFlags: [])
        }

        let timeline = app.buttons[UITestIDs.Cloud.jumpToTimelineButton]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10), "Expected Timeline tab button.")
        timeline.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try capture(largestWindow(in: app), named: "cloud_timeline")

        let transcript = app.buttons[UITestIDs.Cloud.jumpToTranscriptButton]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "Expected Transcription tab button.")
        transcript.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try capture(largestWindow(in: app), named: "cloud_transcription")
        let firstSegmentText = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", UITestIDs.Cloud.transcriptSegmentTextPrefix))
            .firstMatch
        XCTAssertTrue(firstSegmentText.waitForExistence(timeout: 5), "Expected transcript segment text.")
        firstSegmentText.click()
        let segmentSelectDeadline = Date().addingTimeInterval(3)
        while Date() < segmentSelectDeadline, !firstSegmentText.isSelected {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(firstSegmentText.isSelected, "Clicking the transcript text body should select/jump to that segment.")
        let speakerRenameButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", UITestIDs.Cloud.speakerNameButtonPrefix)
        ).firstMatch
        if speakerRenameButton.waitForExistence(timeout: 5) {
            speakerRenameButton.click()
            let renamePopover = uiElement(app, id: UITestIDs.Cloud.speakerRenamePopover)
            XCTAssertTrue(renamePopover.waitForExistence(timeout: 5), "Expected speaker rename popover.")
            try captureScreenRegion(
                around: [largestWindow(in: app), renamePopover],
                named: "cloud_speaker_rename_popover",
                horizontalPadding: 24,
                verticalPadding: 24
            )
            app.typeKey(.escape, modifierFlags: [])
        }

        let searchField = app.descendants(matching: .any)
            .matching(identifier: UITestIDs.Cloud.searchField)
            .firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Expected Cloud search field.")
        searchField.click()
        searchField.typeText("caption")
        let searchResults = uiElement(app, id: UITestIDs.Cloud.searchResults)
        XCTAssertTrue(searchResults.waitForExistence(timeout: 5), "Expected Cloud search results.")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try capture(largestWindow(in: app), named: "cloud_search_results")

        let firstSearchResult = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", UITestIDs.Cloud.searchResultRowPrefix)
        ).firstMatch
        if firstSearchResult.waitForExistence(timeout: 5) {
            firstSearchResult.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            try capture(largestWindow(in: app), named: "cloud_search_jump_highlight")
        }
    }

    private func captureSettingsStates() throws {
        let app = launchStateBoardApp(authToken: "", openSettingsWindowOnLaunch: true)

        let account = settingsTab(in: app, title: "Account", id: UITestIDs.Settings.accountTab)
        XCTAssertTrue(account.waitForExistence(timeout: 15), "Expected Account settings tab.")
        account.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try capture(largestWindow(in: app), named: "settings_account_default")

        let transcription = settingsTab(in: app, title: "Transcription", id: UITestIDs.Settings.transcriptionTab)
        XCTAssertTrue(transcription.waitForExistence(timeout: 10), "Expected Transcription settings tab.")
        transcription.click()
        try capture(largestWindow(in: app), named: "settings_transcription_captions")
    }

    private func settingsTab(in app: XCUIApplication, title: String, id: String) -> XCUIElement {
        let identified = uiElement(app, id: id)
        if identified.exists { return identified }

        let button = app.buttons[title]
        if button.exists { return button }

        let radioButton = app.radioButtons[title]
        if radioButton.exists { return radioButton }

        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR identifier == %@", title, title))
            .firstMatch
    }

    private func captureOnboardingStates() throws {
        let app = launchStateBoardApp(forceOnboarding: true, suppressOnboarding: false)
        let onboarding = uiElement(app, id: "recappi.onboarding.window")
        XCTAssertTrue(onboarding.waitForExistence(timeout: 15), "Expected onboarding window.")
        try capture(largestWindow(in: app), named: "onboarding_intro")

        let primary = uiElement(app, id: "recappi.onboarding.primaryButton")
        if primary.waitForExistence(timeout: 2) {
            primary.click()
            try capture(largestWindow(in: app), named: "onboarding_permissions")
        }
    }

    private func launchStateBoardApp(
        authToken: String? = nil,
        liveCaptionText: String? = nil,
        liveCaptionTranslationText: String? = nil,
        forceOnboarding: Bool = false,
        suppressOnboarding: Bool = true,
        openCloudWindowOnLaunch: Bool = false,
        openSettingsWindowOnLaunch: Bool = false,
        recordingPanelState: String? = nil,
        simulatedAutoPromptApp: (bundleID: String, name: String)? = nil,
        simulatedAutoPromptMeetingLabel: String? = nil,
        detectedMeetingAutoStopGraceSeconds: TimeInterval? = nil
    ) -> XCUIApplication {
        terminateExistingRecappiInstances()

        let app = XCUIApplication(url: UITestPaths.appBundle)
        app.launchEnvironment["RECAPPI_UI_TEST"] = "1"
        app.launchEnvironment["RECAPPI_TEST_STATE_BOARD_FIXTURE"] = "1"
        app.launchEnvironment["RECAPPI_TEST_AUDIO_FIXTURE"] = UITestPaths.recordingFixture.path
        app.launchEnvironment["RECAPPI_TEST_UPLOAD_FIXTURE"] = UITestPaths.uploadFixture.path
        if suppressOnboarding {
            app.launchEnvironment["RECAPPI_TEST_SUPPRESS_ONBOARDING"] = "1"
        }
        if forceOnboarding {
            app.launchEnvironment["RECAPPI_TEST_FORCE_ONBOARDING"] = "1"
        }
        if openSettingsWindowOnLaunch {
            app.launchEnvironment["RECAPPI_TEST_OPEN_SETTINGS_WINDOW"] = "1"
        }
        if openCloudWindowOnLaunch {
            app.launchEnvironment["RECAPPI_TEST_OPEN_CLOUD_WINDOW"] = "1"
        }
        if let recordingPanelState, !recordingPanelState.isEmpty {
            app.launchEnvironment["RECAPPI_TEST_RECORDING_PANEL_STATE"] = recordingPanelState
        }
        if let simulatedAutoPromptApp {
            app.launchEnvironment["RECAPPI_TEST_AUTO_PROMPT_BUNDLE_ID"] = simulatedAutoPromptApp.bundleID
            app.launchEnvironment["RECAPPI_TEST_AUTO_PROMPT_APP_NAME"] = simulatedAutoPromptApp.name
        }
        if let simulatedAutoPromptMeetingLabel, !simulatedAutoPromptMeetingLabel.isEmpty {
            app.launchEnvironment["RECAPPI_TEST_AUTO_PROMPT_MEETING_LABEL"] = simulatedAutoPromptMeetingLabel
        }
        if let detectedMeetingAutoStopGraceSeconds {
            app.launchEnvironment["RECAPPI_TEST_DETECTED_MEETING_AUTOSTOP_GRACE_SECONDS"] = String(detectedMeetingAutoStopGraceSeconds)
        }
        if let authToken {
            app.launchEnvironment["RECAPPI_TEST_AUTH_TOKEN"] = authToken
        }
        if let backend = UITestPaths.backendOverrideValue, !backend.isEmpty {
            app.launchEnvironment["RECAPPI_TEST_BACKEND_URL"] = backend
        }
        if let liveCaptionText, !liveCaptionText.isEmpty {
            app.launchEnvironment["RECAPPI_TEST_LIVE_CAPTION_TEXT"] = liveCaptionText
        }
        if let liveCaptionTranslationText, !liveCaptionTranslationText.isEmpty {
            app.launchEnvironment["RECAPPI_TEST_LIVE_CAPTION_TRANSLATION_TEXT"] = liveCaptionTranslationText
        }

        app.launch()
        addTeardownBlock {
            if app.state != .notRunning {
                app.terminate()
            }
        }
        return app
    }

    private func capture(_ element: XCUIElement, named name: String, overwrite: Bool = true) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Expected element for \(name).")
        let url = outputDirectory.appendingPathComponent("\(name).png")
        if !overwrite, FileManager.default.fileExists(atPath: url.path) {
            return
        }
        try element.screenshot().pngRepresentation.write(to: url, options: [.atomic])
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func captureRecordingPanel(in app: XCUIApplication, named name: String, overwrite: Bool = true) throws {
        let panelElements = panelBoundsElements(in: app)
        if try captureRecappiWindow(near: panelElements, named: name, overwrite: overwrite) {
            return
        }
        try captureScreenRegion(around: panelElements, named: name, overwrite: overwrite)
    }

    private func panelBoundsElements(in app: XCUIApplication) -> [XCUIElement] {
        [
            UITestIDs.Panel.audioSourcePicker,
            UITestIDs.Panel.cloudButton,
            UITestIDs.Panel.closeButton,
            UITestIDs.Panel.recordingOptionsButton,
            UITestIDs.Panel.recordButton,
            UITestIDs.Panel.liveCaptionsButton,
            UITestIDs.Panel.waveformToggle,
            UITestIDs.Panel.microphoneIncludeButton,
            UITestIDs.Panel.stopButton,
            UITestIDs.Panel.processingTitle,
            UITestIDs.Panel.doneTitle,
            UITestIDs.Panel.errorTitle,
            UITestIDs.Panel.transcribeButton,
            UITestIDs.Panel.showButton,
            UITestIDs.Panel.retryButton,
            UITestIDs.Panel.settingsButton
        ]
        .map { uiElement(app, id: $0) }
        .filter {
            $0.exists &&
                $0.frame.width > 1 &&
                $0.frame.height > 1
        }
    }

    private func captureScreenRegion(
        around elements: [XCUIElement],
        named name: String,
        overwrite: Bool = true,
        horizontalPadding: CGFloat = 26,
        verticalPadding: CGFloat = 26
    ) throws {
        let url = outputDirectory.appendingPathComponent("\(name).png")
        if !overwrite, FileManager.default.fileExists(atPath: url.path) {
            return
        }

        let frames = elements.map(\.frame).filter { !$0.isNull && !$0.isEmpty }
        XCTAssertFalse(frames.isEmpty, "Expected panel elements for \(name).")
        let bounds = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
            .insetBy(dx: -horizontalPadding, dy: -verticalPadding)

        let screenshot = XCUIScreen.main.screenshot()
        guard
            let source = CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let screen = NSScreen.screens.first
        else {
            XCTFail("Unable to load screenshot image for \(name).")
            return
        }

        let scale = CGFloat(image.width) / screen.frame.width
        let cropRect = CGRect(
            x: max(0, bounds.minX * scale),
            y: max(0, bounds.minY * scale),
            width: min(CGFloat(image.width), bounds.width * scale),
            height: min(CGFloat(image.height), bounds.height * scale)
        ).integral

        guard let cropped = image.cropping(to: cropRect) else {
            XCTFail("Unable to crop screenshot image for \(name).")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cropped)
        let data = rep.representation(using: .png, properties: [:])
        try XCTUnwrap(data, "Expected PNG data for \(name).").write(to: url, options: [.atomic])

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func captureRecappiWindow(near elements: [XCUIElement], named name: String, overwrite: Bool) throws -> Bool {
        let url = outputDirectory.appendingPathComponent("\(name).png")
        if !overwrite, FileManager.default.fileExists(atPath: url.path) {
            return true
        }

        let frames = elements.map(\.frame).filter { !$0.isNull && !$0.isEmpty }
        guard !frames.isEmpty else { return false }
        let expected = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
            .insetBy(dx: -18, dy: -18)

        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return false
        }

        let candidates = windows.compactMap { window -> (id: CGWindowID, score: CGFloat)? in
            guard
                let owner = window[kCGWindowOwnerName as String] as? String,
                owner.contains("Recappi"),
                let layer = window[kCGWindowLayer as String] as? Int,
                layer == 0,
                let id = window[kCGWindowNumber as String] as? CGWindowID,
                let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                bounds.width > 200,
                bounds.height > 50
            else {
                return nil
            }

            let score = abs(bounds.width - expected.width) + abs(bounds.height - expected.height)
            return (id, score)
        }

        guard let windowID = candidates.min(by: { $0.score < $1.score })?.id else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(windowID), url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            return false
        }

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return true
    }

    private func largestWindow(in app: XCUIApplication) -> XCUIElement {
        let windows = app.windows.allElementsBoundByIndex.filter(\.exists)
        return windows.max { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        } ?? app.windows.firstMatch
    }

    private func prepareOutputDirectory() throws {
        try? FileManager.default.removeItem(at: outputDirectory)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
    }
}
