import XCTest
@testable import RecappiCloudCore

final class RecappiCloudCoreTests: XCTestCase {
    func testOriginResolverPrefersExplicitThenEnvironmentThenAppPreferencesThenDefault() throws {
        let preferenceValues = [
            "recappi.backendOrigin": "https://app.example.com/",
            "backendBaseURL": "https://settings.example.com/",
        ]
        let resolver = RecappiCloudOriginResolver(
            environment: ["RECAPPI_BACKEND_URL": "https://env.example.com/"],
            appPreferenceReader: { preferenceValues[$0] }
        )

        XCTAssertEqual(try resolver.resolve(explicitOrigin: "https://explicit.example.com/"), "https://explicit.example.com")
        XCTAssertEqual(try resolver.resolve(), "https://env.example.com")

        let appResolver = RecappiCloudOriginResolver(environment: [:]) { preferenceValues[$0] }
        XCTAssertEqual(try appResolver.resolve(), "https://app.example.com")

        let defaultResolver = RecappiCloudOriginResolver(environment: [:]) { _ in nil }
        XCTAssertEqual(try defaultResolver.resolve(), "https://recordmeet.ing")
    }

    func testOriginResolverRejectsMalformedOrigins() {
        let resolver = RecappiCloudOriginResolver(environment: [:]) { _ in nil }

        XCTAssertThrowsError(try resolver.resolve(explicitOrigin: "not a url")) { error in
            XCTAssertEqual(error as? RecappiCloudError, .invalidURL)
        }
        XCTAssertThrowsError(try resolver.resolve(explicitOrigin: "ftp://recordmeet.ing")) { error in
            XCTAssertEqual(error as? RecappiCloudError, .invalidURL)
        }
        XCTAssertThrowsError(try resolver.resolve(explicitOrigin: "https://recordmeet.ing/api")) { error in
            XCTAssertEqual(error as? RecappiCloudError, .invalidURL)
        }
    }

    func testAuthContextValidatesOriginBeforeReadingToken() {
        let auth = RecappiCloudAuth(
            credentialStore: RecappiCloudCredentialStore(
                environment: [:],
                keychainReader: { XCTFail("Invalid origin should fail before credential lookup"); return "token" },
                developmentReader: { nil }
            )
        )

        XCTAssertThrowsError(try auth.context(explicitOrigin: "not a url")) { error in
            XCTAssertEqual(error as? RecappiCloudError, .invalidURL)
        }
    }

    func testBearerTokenNormalizationAcceptsBearerAndSetAuthTokenPrefixes() {
        XCTAssertEqual(RecappiCloudCredentialStore.normalizeBearerToken("Bearer abc123"), "abc123")
        XCTAssertEqual(RecappiCloudCredentialStore.normalizeBearerToken("set-auth-token: xyz"), "xyz")
        XCTAssertEqual(RecappiCloudCredentialStore.normalizeBearerToken(" raw-token "), "raw-token")
        XCTAssertNil(RecappiCloudCredentialStore.normalizeBearerToken("   "))
    }

    func testCredentialStorePrefersEnvironmentThenDevelopmentFileThenKeychain() {
        let envStore = RecappiCloudCredentialStore(
            environment: [
                "RECAPPI_AUTH_TOKEN": "Bearer env-token",
                "RECAPPI_USE_FILE_AUTH_STORAGE": "1",
            ],
            keychainReader: { "keychain-token" },
            developmentReader: { "dev-token" }
        )
        XCTAssertEqual(envStore.readBearerToken(), "env-token")

        let devStore = RecappiCloudCredentialStore(
            environment: ["RECAPPI_USE_FILE_AUTH_STORAGE": "1"],
            keychainReader: { "keychain-token" },
            developmentReader: { "set-auth-token: dev-token" }
        )
        XCTAssertEqual(devStore.readBearerToken(), "dev-token")

        let keychainStore = RecappiCloudCredentialStore(
            environment: [:],
            keychainReader: { "Bearer keychain-token" },
            developmentReader: { nil }
        )
        XCTAssertEqual(keychainStore.readBearerToken(), "keychain-token")
    }

    func testCredentialStoreCanDisableKeychainLookup() {
        let store = RecappiCloudCredentialStore(
            environment: ["RECAPPI_DISABLE_KEYCHAIN_AUTH": "1"],
            keychainReader: { XCTFail("Keychain lookup should be disabled"); return "keychain-token" },
            developmentReader: { nil }
        )

        XCTAssertNil(store.readBearerToken())
    }

    func testSupportedUploadContentTypesMatchBackendContract() {
        XCTAssertEqual(RecappiCloudAudioInspector.cloudUploadContentType(for: URL(fileURLWithPath: "/tmp/a.wav")), "audio/wav")
        XCTAssertEqual(RecappiCloudAudioInspector.cloudUploadContentType(for: URL(fileURLWithPath: "/tmp/a.mp3")), "audio/mp3")
        XCTAssertEqual(RecappiCloudAudioInspector.cloudUploadContentType(for: URL(fileURLWithPath: "/tmp/a.m4a")), "audio/aac")
        XCTAssertEqual(RecappiCloudAudioInspector.cloudUploadContentType(for: URL(fileURLWithPath: "/tmp/a.flac")), "audio/flac")
        XCTAssertNil(RecappiCloudAudioInspector.cloudUploadContentType(for: URL(fileURLWithPath: "/tmp/a.txt")))
    }

    func testSessionLookupDecodesNullAsSignedOut() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://recordmeet.ing/api/auth/get-session")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        let lookup = try RecappiCloudAPIClient.decodeSessionLookup(
            from: Data("null".utf8),
            response: response,
            origin: "https://recordmeet.ing"
        )

        XCTAssertNil(lookup.userSession)
        XCTAssertNil(lookup.bearerToken)
    }

    func testJobDecodesSmartChunkProgressWithoutExposingPartShape() throws {
        let data = Data("""
        {
          "id": "job-1",
          "status": "running",
          "transcriptId": null,
          "provider": "gemini",
          "model": "gemini-2.5-pro",
          "language": "en",
          "prompt": null,
          "error": null,
          "attempts": 1,
          "enqueuedAt": 1,
          "startedAt": 2,
          "finishedAt": null,
          "chunkProgress": {
            "total": 4,
            "pending": 1,
            "running": 1,
            "completed": 2,
            "failed": 0,
            "currentIndex": 2,
            "completedDurationMs": 1200000,
            "totalDurationMs": 2400000,
            "percent": 50,
            "chunks": [],
            "failedChunks": [
              {
                "index": 3,
                "startMs": 1800000,
                "endMs": 2400000,
                "retryable": true,
                "message": "Retry this range"
              }
            ]
          }
        }
        """.utf8)

        let job = try JSONDecoder().decode(RecappiCloudJob.self, from: data)

        XCTAssertEqual(job.chunkProgress?.percent, 50)
        XCTAssertEqual(job.chunkProgress?.failedRanges.first?.startMs, 1_800_000)
        XCTAssertEqual(job.chunkProgress?.failedRanges.first?.endMs, 2_400_000)
    }
}
