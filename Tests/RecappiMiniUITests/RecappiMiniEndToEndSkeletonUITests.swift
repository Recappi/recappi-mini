import XCTest

@MainActor
final class RecappiMiniEndToEndSkeletonUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCookieDrivenTranscriptionFlow() throws {
        guard let cookie = UITestPaths.liveCookieValue, !cookie.isEmpty else {
            throw XCTSkip("Set RECAPPI_TEST_COOKIE to run the live backend UI test.")
        }

        let baseline = UITestArtifacts.sessionNames()
        let app = launchRecappiApp(cookie: cookie, disableSummary: true)

        openSettings(from: app)
        verifySessionSucceeds(in: app)
        closeSettingsWindow(in: app)
        startAndStopFixtureRecording(in: app)

        let processingTitle = uiElement(app, id: UITestIDs.Panel.processingTitle)
        XCTAssertTrue(processingTitle.waitForExistence(timeout: 20), "Expected processing UI after stop.")
        waitForCompletion(in: app)

        let sessionDir = try UITestArtifacts.newestSession(excluding: baseline)
        attachArtifacts(for: sessionDir, named: "transcript-only-session")

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("recording.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("upload.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("transcript.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("summary.md").path))
    }

    func testInvalidCookieFlow() throws {
        let app = launchRecappiApp(cookie: "definitely-invalid-cookie", disableSummary: true)

        openSettings(from: app)
        verifySessionFails(in: app, timeout: 15)
    }

    func testCookieDrivenTranscriptionFlowWithSummaryStub() throws {
        guard let cookie = UITestPaths.liveCookieValue, !cookie.isEmpty else {
            throw XCTSkip("Set RECAPPI_TEST_COOKIE to run the live backend summary UI test.")
        }

        let baseline = UITestArtifacts.sessionNames()
        let app = launchRecappiApp(cookie: cookie, enableSummaryStub: true)

        startAndStopFixtureRecording(in: app)
        waitForCompletion(in: app)

        let sessionDir = try UITestArtifacts.newestSession(excluding: baseline)
        attachArtifacts(for: sessionDir, named: "summary-stub-session")

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("summary.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("action-items.md").path))
    }
}
