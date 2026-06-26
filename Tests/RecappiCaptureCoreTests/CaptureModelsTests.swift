import XCTest
@testable import RecappiCaptureCore

final class CaptureModelsTests: XCTestCase {
    func testCaptureSourceUsesStableWireKeys() throws {
        let source = CaptureSource(
            id: "app:company.thebrowser.Browser",
            kind: .app,
            label: "Arc",
            appName: "Arc",
            bundleID: "company.thebrowser.Browser"
        )

        let decoded = try JSONDecoder().decode(CaptureSource.self, from: encoded(source))

        XCTAssertEqual(decoded, source)
        let object = try jsonObject(from: source)
        XCTAssertEqual(object["bundleId"] as? String, "company.thebrowser.Browser")
        XCTAssertNil(object["bundleID"])
    }

    func testCaptureSelectionUsesStableWireKeys() throws {
        let selection = CaptureSelection(
            sourceID: "system",
            includeMicrophone: true,
            microphoneDeviceID: "BuiltInMicrophoneDevice"
        )

        let decoded = try JSONDecoder().decode(CaptureSelection.self, from: encoded(selection))

        XCTAssertEqual(decoded, selection)
        let object = try jsonObject(from: selection)
        XCTAssertEqual(object["sourceId"] as? String, "system")
        XCTAssertEqual(object["microphoneDeviceId"] as? String, "BuiltInMicrophoneDevice")
        XCTAssertNil(object["sourceID"])
        XCTAssertNil(object["microphoneDeviceID"])
    }

    func testCaptureLevelOnlyAllowsPhysicalInputLanes() throws {
        let system = CaptureLevel(input: .system, rmsDb: -35.5, atMs: 123)
        let microphone = CaptureLevel(input: .microphone, rmsDb: -20, atMs: 124)

        XCTAssertEqual(try JSONDecoder().decode(CaptureLevel.self, from: encoded(system)), system)
        XCTAssertEqual(try JSONDecoder().decode(CaptureLevel.self, from: encoded(microphone)), microphone)

        let mixed = #"{"input":"mixed","rmsDb":-12,"atMs":125}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(CaptureLevel.self, from: mixed))
    }

    func testPermissionRestartFlagRoundTrips() throws {
        let permissions = CapturePermissions(
            screenRecording: CapturePermission(status: .granted, requiresProcessRestart: true),
            microphone: CapturePermission(status: .granted)
        )

        let decoded = try JSONDecoder().decode(CapturePermissions.self, from: encoded(permissions))

        XCTAssertEqual(decoded, permissions)
        XCTAssertTrue(decoded.screenRecording.requiresProcessRestart)
        XCTAssertFalse(decoded.microphone?.requiresProcessRestart ?? true)
    }

    func testArtifactCarriesEffectiveSelectionAndAudioURLs() throws {
        let artifact = CaptureArtifact(
            sessionDirectoryURL: URL(fileURLWithPath: "/tmp/recappi/session"),
            mixedAudioURL: URL(fileURLWithPath: "/tmp/recappi/session/recording.m4a"),
            systemAudioURL: URL(fileURLWithPath: "/tmp/recappi/session/system.caf"),
            durationMs: 42_000,
            diagnostics: ["meanDb": "-34.78"],
            effectiveSelection: CaptureSelection(sourceID: "system", includeMicrophone: false)
        )

        let decoded = try JSONDecoder().decode(CaptureArtifact.self, from: encoded(artifact))

        XCTAssertEqual(decoded, artifact)
        XCTAssertEqual(decoded.effectiveSelection.sourceID, "system")
        XCTAssertEqual(decoded.diagnostics["meanDb"], "-34.78")
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private func jsonObject<T: Encodable>(from value: T) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: encoded(value))
        return try XCTUnwrap(object as? [String: Any])
    }
}
