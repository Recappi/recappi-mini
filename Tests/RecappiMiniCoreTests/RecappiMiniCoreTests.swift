import AVFoundation
import XCTest
@testable import RecappiMini

final class RecappiMiniCoreTests: XCTestCase {
    func testNormalizeBearerSupportsRawTokenAndHeader() throws {
        XCTAssertEqual(AuthSessionStore.normalizeBearerToken("abc.123"), "abc.123")
        XCTAssertEqual(AuthSessionStore.normalizeBearerToken("Bearer xyz.789"), "xyz.789")
        XCTAssertEqual(AuthSessionStore.normalizeBearerToken("set-auth-token: qwe.456"), "qwe.456")
    }

    func testResolveBearerTokenOnlyUsesSetAuthHeader() {
        XCTAssertEqual(
            RecappiAPIClient.resolveBearerToken(headerToken: "set-auth-token: header.123"),
            "header.123"
        )
        XCTAssertNil(RecappiAPIClient.resolveBearerToken(headerToken: nil))
    }

    func testDecodeSessionLookupDoesNotTreatPayloadSessionTokenAsBearer() throws {
        let data = """
        {
          "session": {
            "expiresAt": "2026-05-22T00:00:00.000Z",
            "token": "raw-session-token"
          },
          "user": {
            "id": "user_123",
            "email": "user@example.com",
            "name": "Recappi User",
            "image": null
          }
        }
        """.data(using: .utf8)!
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(URL(string: "https://recordmeet.ing/api/auth/get-session")),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )

        let lookup = try RecappiAPIClient.decodeSessionLookup(
            from: data,
            response: response,
            origin: "https://recordmeet.ing"
        )

        XCTAssertEqual(lookup.userSession?.email, "user@example.com")
        XCTAssertNil(lookup.bearerToken)
    }

    func testBearerSessionDisablesCookies() {
        let session = RecappiNetworking.makeBearerSession()
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertEqual(session.configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(session.configuration.httpCookieStorage)
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

    func testNativeOAuthUsesBrowserKickoffPage() throws {
        let url = try NativeOAuthCoordinator.nativeLoginKickoffURL(
            origin: "https://recordmeet.ing/",
            provider: .google,
            challenge: String(repeating: "A", count: 43)
        )

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "recordmeet.ing")
        XCTAssertEqual(url.path, "/login")

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["native"], "1")
        XCTAssertEqual(items["provider"], "google")
        XCTAssertEqual(
            items["callbackURL"],
            "https://recordmeet.ing/api/native-oauth-bridge?challenge=\(String(repeating: "A", count: 43))"
        )
        XCTAssertEqual(items["errorCallbackURL"], items["callbackURL"])
    }

    func testNativeOAuthExtractsBridgeExchangeCode() throws {
        let callbackURL = try XCTUnwrap(URL(string: "recappi://auth/callback?code=bridge-code-123"))
        XCTAssertEqual(
            try NativeOAuthCoordinator.extractExchangeCode(from: callbackURL),
            "bridge-code-123"
        )
    }

    func testAuthFlowPhaseProvidesUserFacingLabels() {
        XCTAssertEqual(
            AuthFlowPhase.awaitingUserInteraction(provider: .google).statusText,
            "Continue with Google in the secure browser sheet."
        )
        XCTAssertEqual(
            AuthFlowPhase.exchangingCode(provider: .github).buttonLabel,
            "Finishing…"
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
