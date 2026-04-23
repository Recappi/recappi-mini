import XCTest

final class AutomationHarnessTests: XCTestCase {
    func testAutomationScriptsExist() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: AutomationPaths.fixtureScript.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AutomationPaths.buildAppScript.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AutomationPaths.automationScript.path))
    }

    func testGeneratedFixturesExistAndAreNonEmpty() throws {
        let recordingAttributes = try FileManager.default.attributesOfItem(atPath: AutomationPaths.recordingFixture.path)
        let uploadAttributes = try FileManager.default.attributesOfItem(atPath: AutomationPaths.uploadFixture.path)

        XCTAssertGreaterThan((recordingAttributes[.size] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertGreaterThan((uploadAttributes[.size] as? NSNumber)?.intValue ?? 0, 0)
    }

    func testFixtureManifestContainsExpectedArtifacts() throws {
        let data = try Data(contentsOf: AutomationPaths.fixtureManifest)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let artifacts = try XCTUnwrap(payload["artifacts"] as? [String: Any])

        XCTAssertEqual(artifacts["recording_m4a"] as? String, "automation-recording.m4a")
        XCTAssertEqual(artifacts["upload_wav"] as? String, "automation-upload.wav")
        XCTAssertEqual(payload["generator"] as? String, "scripts/generate-test-audio-fixtures.sh")
    }

    func testRecordingFixtureLooksLikeHighQualityM4A() throws {
        let output = try Shell.run("/usr/bin/afinfo", arguments: [AutomationPaths.recordingFixture.path])
        XCTAssertTrue(output.contains("m4af") || output.contains("File type ID:   m4af"))
        XCTAssertTrue(output.contains("48000 Hz"))
        XCTAssertTrue(output.contains("2 ch"))
    }

    func testUploadFixtureLooksLikeMono16kWav() throws {
        let output = try Shell.run("/usr/bin/afinfo", arguments: [AutomationPaths.uploadFixture.path])
        XCTAssertTrue(output.contains("File type ID: WAVE") || output.contains("WAVE"))
        XCTAssertTrue(output.contains("16000 Hz"))
        XCTAssertTrue(output.contains("1 ch"))
    }

    func testReadmeDocumentsRuntimeHooks() throws {
        let readme = try String(
            contentsOf: AutomationPaths.repoRoot.appendingPathComponent("Tests/README.md"),
            encoding: .utf8
        )
        XCTAssertTrue(readme.contains("RECAPPI_UI_TEST"))
        XCTAssertTrue(readme.contains("accessibility identifiers"))
        XCTAssertTrue(readme.contains("RECAPPI_TEST_AUTH_TOKEN"))
    }
}
