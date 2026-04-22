import AVFoundation
import XCTest
@testable import RecappiMini

final class RecappiMiniCoreTests: XCTestCase {
    func testNormalizeBearerSupportsRawTokenAndHeader() throws {
        XCTAssertEqual(AuthSessionStore.normalizeBearerToken("abc.123"), "abc.123")
        XCTAssertEqual(AuthSessionStore.normalizeBearerToken("Bearer xyz.789"), "xyz.789")
        XCTAssertEqual(AuthSessionStore.normalizeBearerToken("set-auth-token: qwe.456"), "qwe.456")
    }

    func testResolveBearerTokenFallsBackFromHeaderToPayload() {
        XCTAssertEqual(
            RecappiAPIClient.resolveBearerToken(headerToken: "set-auth-token: header.123", payloadToken: "body.456"),
            "header.123"
        )
        XCTAssertEqual(
            RecappiAPIClient.resolveBearerToken(headerToken: nil, payloadToken: "body.456"),
            "body.456"
        )
    }

    func testNativeOAuthUsesBridgeCallbackScheme() throws {
        XCTAssertEqual(NativeOAuthCoordinator.callbackScheme, "recappi")
        XCTAssertEqual(NativeOAuthCoordinator.callbackHost, "auth")
        XCTAssertEqual(NativeOAuthCoordinator.callbackPath, "/callback")

        let url = try NativeOAuthCoordinator.bridgeCallbackURL(
            origin: "https://recordmeet.ing/",
            challenge: String(repeating: "A", count: 43)
        )
        XCTAssertEqual(
            url,
            "https://recordmeet.ing/api/native-oauth-bridge?challenge=\(String(repeating: "A", count: 43))"
        )
    }

    @MainActor
    func testNormalizedCloudLanguageUsesBaseCode() {
        let config = AppConfig.shared
        let original = config.cloudLanguage
        defer { config.cloudLanguage = original }

        config.cloudLanguage = "zh-CN"
        XCTAssertEqual(config.normalizedCloudLanguage, "zh")

        config.cloudLanguage = "en-US"
        XCTAssertEqual(config.normalizedCloudLanguage, "en")
    }

    func testRemoteManifestRoundTrip() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        var manifest = RemoteSessionManifest.stage("uploading")
        manifest.recordingId = "rec_123"
        manifest.jobId = "job_123"
        _ = RecordingStore.saveRemoteManifest(manifest, in: temp)

        let loaded = try XCTUnwrap(RecordingStore.loadRemoteManifest(in: temp))
        XCTAssertEqual(loaded.recordingId, "rec_123")
        XCTAssertEqual(loaded.jobId, "job_123")
        XCTAssertEqual(loaded.stage, "uploading")
    }

    func testUploadAudioExporterProducesWaveSidecar() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let source = RecordingStore.audioFileURL(in: temp)
        try FileManager.default.copyItem(at: AutomationPaths.recordingFixture, to: source)

        let output = try await UploadAudioExporter.ensureUploadAudio(for: temp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(output.lastPathComponent, "upload.wav")

        let audioFile = try AVAudioFile(forReading: output)
        XCTAssertEqual(Int(audioFile.fileFormat.sampleRate.rounded()), 16_000)
        XCTAssertEqual(audioFile.fileFormat.channelCount, 1)
    }

}
