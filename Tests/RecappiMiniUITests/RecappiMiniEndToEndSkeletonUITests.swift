import XCTest

@MainActor
final class RecappiMiniEndToEndSkeletonUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPersistedSessionTranscriptionFlow() throws {
        let baseline = UITestArtifacts.sessionNames()
        let app = launchRecappiApp(authToken: "")

        openSettings(from: app)
        try ensureSignedInByReauthIfNeeded(in: app)
        closeSettingsWindow(in: app)
        startAndStopFixtureRecording(in: app)

        let processingTitle = uiElement(app, id: UITestIDs.Panel.processingTitle)
        XCTAssertTrue(processingTitle.waitForExistence(timeout: 20), "Expected processing UI after stop.")
        waitForCompletion(in: app)

        let sessionDir = try UITestArtifacts.newestSession(excluding: baseline)
        attachArtifacts(for: sessionDir, named: "persisted-session-smoke")

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("recording.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("upload.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("transcript.md").path))
    }

    func testBearerDrivenTranscriptionFlow() throws {
        guard let authToken = UITestPaths.liveAuthTokenValue, !authToken.isEmpty else {
            throw XCTSkip("Set RECAPPI_TEST_AUTH_TOKEN to run the live backend UI test.")
        }

        let baseline = UITestArtifacts.sessionNames()
        let app = launchRecappiApp(authToken: authToken)

        openSettings(from: app)
        waitForSignedInStatus(in: app)
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("action-items.md").path))
    }

    func testInvalidBearerFlow() throws {
        let app = launchRecappiApp(authToken: "definitely-invalid-auth-token")

        openSettings(from: app)
        waitForFailedStatus(in: app, timeout: 15)
    }

    func testSignOutReturnsToSignedOutState() throws {
        guard let authToken = UITestPaths.liveAuthTokenValue, !authToken.isEmpty else {
            throw XCTSkip("Set RECAPPI_TEST_AUTH_TOKEN to run the sign-out UI test.")
        }

        let app = launchRecappiApp(authToken: authToken)

        openSettings(from: app)
        waitForSignedInStatus(in: app)
        signOut(in: app)
        waitForFailedStatus(in: app, timeout: 15)
    }
}
