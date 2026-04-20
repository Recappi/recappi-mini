import AVFoundation
import XCTest
@testable import RecappiMini

final class RecappiMiniCoreTests: XCTestCase {
    func testNormalizeBearerSupportsRawTokenAndHeader() throws {
        XCTAssertEqual(AuthSessionStore.normalizeBearerToken("abc.123"), "abc.123")
        XCTAssertEqual(AuthSessionStore.normalizeBearerToken("Bearer xyz.789"), "xyz.789")
        XCTAssertEqual(AuthSessionStore.normalizeBearerToken("set-auth-token: qwe.456"), "qwe.456")
    }

    func testNormalizeCookieSupportsRawValue() throws {
        let normalized = try XCTUnwrap(AuthSessionStore.normalizeCookieHeader("abc.123"))
        XCTAssertEqual(normalized.value, "abc.123")
        XCTAssertEqual(normalized.header, "__Secure-better-auth.session_token=abc.123")
    }

    func testNormalizeCookieSupportsBothCookieNames() throws {
        let secure = try XCTUnwrap(AuthSessionStore.normalizeCookieHeader("__Secure-better-auth.session_token=secure; foo=bar"))
        XCTAssertEqual(secure.value, "secure")

        let plain = try XCTUnwrap(AuthSessionStore.normalizeCookieHeader("better-auth.session_token=plain"))
        XCTAssertEqual(plain.value, "plain")
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

    func testUITestSummaryStubUsesFixtureText() {
        let transcript = "Recappi automation transcript body."
        let insights = SessionProcessor.makeUITestStubInsights(from: transcript)

        XCTAssertTrue(insights.summary.contains("Automation Summary"))
        XCTAssertTrue(insights.summary.contains("Recappi automation transcript body"))
        XCTAssertEqual(insights.actionItems.count, 2)
    }
}
