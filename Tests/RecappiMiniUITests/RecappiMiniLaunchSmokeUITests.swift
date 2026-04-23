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
}
