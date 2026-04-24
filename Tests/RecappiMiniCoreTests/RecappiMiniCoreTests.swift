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

    func testCaptureStreamFormatClampsMultiChannelSourcesToStereo() {
        let format = CaptureStreamFormat(sampleRate: 96_000, channelCount: 8)

        XCTAssertEqual(format.sampleRate, 96_000)
        XCTAssertEqual(format.channelCount, 2)
        XCTAssertEqual(format.recommendedBitRate, 128_000)
    }

    func testCaptureStreamFormatFallsBackToMinimumUsableFormat() {
        let format = CaptureStreamFormat(sampleRate: 0, channelCount: 0)

        XCTAssertEqual(format.sampleRate, 1)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.recommendedBitRate, 64_000)
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

    func testCloudLibraryListRequestUsesBearerAndOrigin() throws {
        let client = RecappiAPIClient(origin: "https://recordmeet.ing/", bearerToken: "token_123")
        let request = try client.makeRequest(
            path: "/api/recordings",
            queryItems: [
                URLQueryItem(name: "limit", value: "20"),
                URLQueryItem(name: "cursor", value: "cursor_abc"),
            ]
        )

        XCTAssertEqual(request.url?.absoluteString, "https://recordmeet.ing/api/recordings?limit=20&cursor=cursor_abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://recordmeet.ing")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token_123")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testCloudTranscriptRequestUsesOptionalJobQuery() throws {
        let client = RecappiAPIClient(origin: "https://recordmeet.ing", bearerToken: "token_123")
        let request = try client.makeRequest(
            path: "/api/recordings/rec_123/transcript",
            queryItems: [URLQueryItem(name: "jobId", value: "job_123")]
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://recordmeet.ing/api/recordings/rec_123/transcript?jobId=job_123"
        )
    }

    func testCloudLibraryLatestTranscriptRequestDoesNotUseActiveTranscriptIdAsJobId() throws {
        let client = RecappiAPIClient(origin: "https://recordmeet.ing", bearerToken: "token_123")
        let request = try client.makeRequest(path: "/api/recordings/rec_123/transcript")

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://recordmeet.ing/api/recordings/rec_123/transcript"
        )
    }

    func testBillingStatusRequestUsesBearerAndOrigin() throws {
        let client = RecappiAPIClient(origin: "https://recordmeet.ing", bearerToken: "token_123")
        let request = try client.makeRequest(path: "/api/billing/status")

        XCTAssertEqual(request.url?.absoluteString, "https://recordmeet.ing/api/billing/status")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://recordmeet.ing")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token_123")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testBillingStatusDecodingAcceptsBackendMillisecondTimestamps() throws {
        let data = """
        {
          "tier": "free",
          "periodStart": 1776834706311,
          "periodEnd": 1779426706311,
          "storageBytes": 13482642,
          "storageCapBytes": 1073741824,
          "minutesUsed": 20,
          "minutesCap": 120,
          "isOverStorage": false,
          "isOverMinutes": false
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(BillingStatus.self, from: data)

        XCTAssertEqual(status.tier, .free)
        XCTAssertEqual(status.storageBytes, 13_482_642)
        XCTAssertEqual(status.storageCapBytes, 1_073_741_824)
        XCTAssertEqual(status.minutesUsed, 20)
        XCTAssertEqual(status.minutesCap, 120)
        XCTAssertFalse(status.isOverStorage)
        XCTAssertFalse(status.isOverMinutes)
        XCTAssertEqual(Int(status.periodEnd?.timeIntervalSince1970 ?? 0), 1_779_426_706)
    }

    func testCloudRecordingListDecoding() throws {
        let data = """
        {
          "items": [
            {
              "id": "rec_123",
              "userId": "user_123",
              "title": "Weekly sync",
              "r2Key": "recordings/user_123/rec_123.wav",
              "r2UploadId": null,
              "status": "ready",
              "sizeBytes": 456789,
              "durationMs": 123456,
              "sampleRate": 48000,
              "channels": 2,
              "contentType": "audio/wav",
              "activeTranscriptId": "tr_123",
              "createdAt": "2026-04-24T08:00:00.000Z",
              "updatedAt": "2026-04-24T08:03:00.000Z"
            }
          ],
          "nextCursor": "next_456"
        }
        """.data(using: .utf8)!

        let page = try JSONDecoder().decode(CloudRecordingsPage.self, from: data)

        XCTAssertEqual(page.nextCursor, "next_456")
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.id, "rec_123")
        XCTAssertEqual(page.items.first?.title, "Weekly sync")
        XCTAssertEqual(page.items.first?.status, .ready)
        XCTAssertEqual(page.items.first?.durationMs, 123456)
        XCTAssertEqual(page.items.first?.contentType, "audio/wav")
        XCTAssertEqual(
            page.items.first?.createdAt,
            ISO8601DateFormatter().date(from: "2026-04-24T08:00:00Z")
        )
    }

    func testCloudRecordingListDecodingAcceptsBackendMillisecondTimestamps() throws {
        let data = """
        {
          "items": [
            {
              "id": "rec_123",
              "status": "ready",
              "createdAt": 1776957994323,
              "updatedAt": 1776958013234
            }
          ],
          "nextCursor": "1776957994323"
        }
        """.data(using: .utf8)!

        let page = try JSONDecoder().decode(CloudRecordingsPage.self, from: data)

        XCTAssertEqual(page.nextCursor, "1776957994323")
        XCTAssertEqual(Int(page.items[0].createdAt?.timeIntervalSince1970 ?? 0), 1_776_957_994)
        XCTAssertEqual(Int(page.items[0].updatedAt?.timeIntervalSince1970 ?? 0), 1_776_958_013)
    }

    func testCloudRecordingDecodingAcceptsSourceMetadata() throws {
        let data = """
        {
          "id": "rec_123",
          "title": "Google Meet in Safari",
          "summaryTitle": "Design review",
          "sourceAppName": "Safari",
          "sourceAppBundleID": "com.apple.Safari",
          "status": "ready",
          "metadata": {
            "sourceTitle": "Google Meet in Safari"
          }
        }
        """.data(using: .utf8)!

        let recording = try JSONDecoder().decode(CloudRecording.self, from: data)

        XCTAssertEqual(recording.title, "Google Meet in Safari")
        XCTAssertEqual(recording.summaryTitle, "Design review")
        XCTAssertEqual(recording.sourceTitle, "Google Meet in Safari")
        XCTAssertEqual(recording.sourceAppName, "Safari")
        XCTAssertEqual(recording.sourceAppBundleID, "com.apple.Safari")
    }

    func testRecordingSessionMetadataBuildsHumanCloudTitle() throws {
        let metadata = RecordingSessionMetadata.capture(
            sourceTitle: "Google Meet in Safari",
            sourceAppName: "Safari",
            sourceBundleID: "com.apple.Safari"
        )

        XCTAssertEqual(metadata.cloudRecordingTitle, "Google Meet in Safari")

        let allSystem = RecordingSessionMetadata.capture(
            sourceTitle: "All system audio",
            sourceAppName: nil,
            sourceBundleID: nil
        )

        XCTAssertEqual(allSystem.cloudRecordingTitle, "Audio recording")
    }

    func testCloudRecordingDecodingKeepsUnknownStatusReadable() throws {
        let data = """
        {
          "id": "rec_123",
          "status": "processing_audio"
        }
        """.data(using: .utf8)!

        let recording = try JSONDecoder().decode(CloudRecording.self, from: data)

        XCTAssertEqual(recording.status, .unknown("processing_audio"))
        XCTAssertEqual(recording.status.displayName, "Processing Audio")
    }

    func testUnauthorizedResponseMapsToExpiredAuthPath() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(URL(string: "https://recordmeet.ing/api/recordings")),
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )
        )

        XCTAssertThrowsError(try RecappiAPIClient.validate(response: response, data: Data())) { error in
            XCTAssertEqual(error as? RecappiAPIError, .unauthorized)
        }
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

    func testAudioMixerProducesHighQualityRecordingArtifact() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let destination = temp.appendingPathComponent("mixed-recording.m4a")

        try await AudioMixer.mix(
            sources: [AutomationPaths.recordingFixture],
            to: destination
        )

        let audioFile = try AVAudioFile(forReading: destination)
        XCTAssertEqual(Int(audioFile.fileFormat.sampleRate.rounded()), 48_000)
        XCTAssertEqual(audioFile.fileFormat.channelCount, 2)
    }

    func testAudioMixerAveragesHotMicAndSystemSources() async throws {
        XCTAssertEqual(AudioMixer.outputHeadroom(forSourceCount: 1), 1.0)
        XCTAssertEqual(AudioMixer.outputHeadroom(forSourceCount: 2), 0.5)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let systemURL = temp.appendingPathComponent("system.caf")
        let micURL = temp.appendingPathComponent("mic.caf")
        let destination = temp.appendingPathComponent("mixed-recording.m4a")

        try writeTone(
            to: systemURL,
            frequency: 440,
            sampleRate: 48_000,
            channels: 2,
            duration: 0.25,
            amplitude: 0.5
        )
        try writeTone(
            to: micURL,
            frequency: 440,
            sampleRate: 48_000,
            channels: 1,
            duration: 0.25,
            amplitude: 0.5
        )

        try await AudioMixer.mix(
            sources: [systemURL, micURL],
            to: destination
        )

        let peak = try peakAmplitude(in: destination)
        XCTAssertGreaterThan(peak, 0.35)
        XCTAssertLessThan(peak, 0.58)
    }

    func testSpectrumBucketsReachHighFrequencyBucketsForHighTone() {
        let sampleRate = 48_000.0
        let samples = sineWave(
            frequency: 6_000,
            sampleRate: sampleRate,
            duration: 0.12,
            amplitude: 0.9
        )

        let bands = AudioLevelExtractor.analyzeSamplesForTesting(samples, sampleRate: sampleRate)
        let peakIndex = bands.enumerated().max(by: { $0.element < $1.element })?.offset

        XCTAssertNotNil(peakIndex)
        XCTAssertGreaterThanOrEqual(peakIndex ?? 0, Int(Double(bands.count) * 0.68))
    }

    func testSpectrumBucketsSpreadAcrossRangeForMultiBandSignal() {
        let sampleRate = 48_000.0
        let components: [(Double, Float)] = [
            (120, 0.92),
            (320, 0.82),
            (760, 0.8),
            (1_600, 0.78),
            (3_200, 0.72),
            (6_400, 0.78),
            (9_600, 0.72),
        ]
        let samples = mixedSineWave(
            components: components,
            sampleRate: sampleRate,
            duration: 0.14
        )

        let bands = AudioLevelExtractor.analyzeSamplesForTesting(samples, sampleRate: sampleRate)
        let third = max(bands.count / 3, 1)
        let leftPeak = bands[..<third].max() ?? 0
        let midPeak = bands[third..<(third * 2)].max() ?? 0
        let rightPeak = bands[(third * 2)...].max() ?? 0
        let leftAverage = bands[..<third].reduce(0, +) / Float(third)
        let rightCount = max(bands.count - (third * 2), 1)
        let rightAverage = bands[(third * 2)...].reduce(0, +) / Float(rightCount)

        XCTAssertGreaterThan(leftPeak, 0.4)
        XCTAssertGreaterThan(midPeak, 0.32)
        XCTAssertGreaterThan(rightPeak, 0.32)
        XCTAssertGreaterThan(rightAverage, leftAverage * 0.33)
    }

    func testSpectrumBucketsKeepUpperHalfVisibleForMusicTilt() {
        let sampleRate = 48_000.0
        let components: [(Double, Float)] = [
            (90, 1.0),
            (180, 0.92),
            (360, 0.82),
            (720, 0.7),
            (1_440, 0.56),
            (2_880, 0.42),
            (5_760, 0.3),
        ]
        let samples = mixedSineWave(
            components: components,
            sampleRate: sampleRate,
            duration: 0.16
        )

        let bands = AudioLevelExtractor.analyzeSamplesForTesting(samples, sampleRate: sampleRate)
        let rightHalf = Array(bands[(bands.count / 2)...])
        let visiblyActiveUpperBands = rightHalf.filter { $0 > 0.16 }.count
        let upperPeak = rightHalf.max() ?? 0

        XCTAssertGreaterThanOrEqual(visiblyActiveUpperBands, 6)
        XCTAssertGreaterThan(upperPeak, 0.3)
    }

    func testDotMatrixKeepsUpperHalfVisibleForMusicTilt() {
        let sampleRate = 48_000.0
        let components: [(Double, Float)] = [
            (90, 1.0),
            (180, 0.95),
            (360, 0.82),
            (720, 0.7),
            (1_440, 0.56),
            (2_880, 0.42),
            (5_760, 0.3),
        ]
        let samples = mixedSineWave(
            components: components,
            sampleRate: sampleRate,
            duration: 0.16
        )

        let bands = AudioLevelExtractor.analyzeSamplesForTesting(samples, sampleRate: sampleRate)
        let litRows = DotMatrixWaveformModel.litRowCounts(for: bands)
        let visibleColumns = litRows.filter { $0 > 0 }.count
        let rightHalfVisibleColumns = litRows[(litRows.count / 2)...].filter { $0 > 0 }.count

        XCTAssertGreaterThanOrEqual(visibleColumns, 18)
        XCTAssertGreaterThanOrEqual(rightHalfVisibleColumns, 8)
    }

    func testDotMatrixLeavesSilenceUnlit() {
        let litRows = DotMatrixWaveformModel.litRowCounts(for: Array(repeating: 0, count: 40))
        XCTAssertTrue(litRows.allSatisfy { $0 == 0 })
    }

    @MainActor
    func testSpectrumConfigurationMatchesRecorderDisplayWidth() {
        XCTAssertEqual(AudioSpectrumConfiguration.bucketCount, AudioRecorder.spectrumBucketCount)

        let sampleRate = 48_000.0
        let samples = mixedSineWave(
            components: [(180, 1.0), (1_000, 0.7), (4_000, 0.45)],
            sampleRate: sampleRate,
            duration: 0.1
        )
        let bands = AudioLevelExtractor.analyzeSamplesForTesting(samples, sampleRate: sampleRate)
        XCTAssertEqual(bands.count, AudioSpectrumConfiguration.bucketCount)
    }

    @MainActor
    func testAutoPromptCandidatePrefersMeetingAppOverBrowser() {
        let browser = makeAudioApp(
            id: "com.google.Chrome",
            name: "Google Chrome",
            bucket: .browser,
            isActive: true
        )
        let meeting = makeAudioApp(
            id: "us.zoom.xos",
            name: "Zoom",
            bucket: .meeting,
            isActive: true
        )
        let other = makeAudioApp(
            id: "com.apple.Music",
            name: "Music",
            bucket: .other,
            isActive: true
        )

        let candidate = AudioRecorder.autoPromptCandidate(
            from: [browser, other, meeting],
            active: ["com.google.Chrome", "us.zoom.xos", "com.apple.Music"]
        )

        XCTAssertEqual(candidate?.id, "us.zoom.xos")
    }

    @MainActor
    func testAutoPromptCandidateIgnoresOtherAndInactiveApps() {
        let inactiveMeeting = makeAudioApp(
            id: "com.microsoft.teams2",
            name: "Microsoft Teams",
            bucket: .meeting,
            isActive: false
        )
        let activeOther = makeAudioApp(
            id: "com.apple.Music",
            name: "Music",
            bucket: .other,
            isActive: true
        )

        XCTAssertNil(AudioRecorder.autoPromptCandidate(
            from: [inactiveMeeting, activeOther],
            active: ["com.apple.Music"]
        ))
    }

    @MainActor
    func testAutoPromptCandidateSkipsBrowserOnlyAudio() {
        let browser = makeAudioApp(
            id: "com.google.Chrome",
            name: "Google Chrome",
            bucket: .browser,
            isActive: true
        )

        XCTAssertNil(AudioRecorder.autoPromptCandidate(
            from: [browser],
            active: ["com.google.Chrome"]
        ))
    }

    @MainActor
    func testRecordingSuggestionDoesNotReplaceCurrentSourceUntilAccepted() {
        let recorder = AudioRecorder()
        let zoom = makeAudioApp(
            id: "us.zoom.xos",
            name: "Zoom",
            bucket: .meeting,
            isActive: true
        )
        recorder.runningApps = [zoom]

        recorder.suggestRecording(for: zoom)

        XCTAssertNil(recorder.selectedApp)
        XCTAssertEqual(recorder.recordingSuggestion?.appID, "us.zoom.xos")
        XCTAssertTrue(recorder.acceptRecordingSuggestion())
        XCTAssertEqual(recorder.selectedApp?.id, "us.zoom.xos")
        XCTAssertNil(recorder.recordingSuggestion)
    }

    func testBrowserMeetingDetectorClassifiesGoogleMeet() {
        let match = BrowserMeetingDetector.classify(
            urlString: "https://meet.google.com/abc-defg-hij",
            title: "Daily sync",
            browserName: "Safari"
        )

        XCTAssertEqual(match?.meetingName, "Google Meet")
        XCTAssertEqual(match?.suggestionTitle, "Google Meet in Safari")
    }

    func testBrowserMeetingDetectorClassifiesTeamsAndZoomWeb() {
        let teams = BrowserMeetingDetector.classify(
            urlString: "https://teams.microsoft.com/l/meetup-join/123",
            title: "Teams call",
            browserName: "Google Chrome"
        )
        let zoom = BrowserMeetingDetector.classify(
            urlString: "https://app.zoom.us/wc/123456/start",
            title: "Zoom",
            browserName: "Google Chrome"
        )

        XCTAssertEqual(teams?.meetingName, "Microsoft Teams")
        XCTAssertEqual(zoom?.meetingName, "Zoom Web")
    }

    func testBrowserMeetingDetectorIgnoresUnknownHosts() {
        XCTAssertNil(BrowserMeetingDetector.classify(
            urlString: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "video",
            browserName: "Safari"
        ))
    }

    private func sineWave(
        frequency: Double,
        sampleRate: Double,
        duration: Double,
        amplitude: Float
    ) -> [Float] {
        let frameCount = Int(sampleRate * duration)
        return (0..<frameCount).map { index in
            let time = Double(index) / sampleRate
            return amplitude * Float(sin(2 * .pi * frequency * time))
        }
    }

    private func mixedSineWave(
        components: [(frequency: Double, amplitude: Float)],
        sampleRate: Double,
        duration: Double
    ) -> [Float] {
        let frameCount = Int(sampleRate * duration)
        return (0..<frameCount).map { index in
            let time = Double(index) / sampleRate
            let sum = components.reduce(0.0) { partial, component in
                partial + (Double(component.amplitude) * sin(2 * .pi * component.frequency * time))
            }
            return Float(max(-1, min(1, sum / Double(components.count))))
        }
    }

    private func writeTone(
        to url: URL,
        frequency: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        duration: Double,
        amplitude: Float
    ) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleRate * duration)
              ),
              let channelData = buffer.floatChannelData else {
            XCTFail("Failed to create tone buffer")
            return
        }

        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            let sample = amplitude * Float(sin(2 * .pi * frequency * Double(frame) / sampleRate))
            for channel in 0..<Int(channels) {
                channelData[channel][frame] = sample
            }
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func peakAmplitude(in url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            XCTFail("Failed to create read buffer")
            return 0
        }

        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            XCTFail("Failed to read float channel data")
            return 0
        }

        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channelData[channel][frame]))
            }
        }
        return peak
    }

    private func makeAudioApp(
        id: String,
        name: String,
        bucket: AudioApp.Bucket,
        isActive: Bool
    ) -> AudioApp {
        AudioApp(
            id: id,
            name: name,
            icon: nil,
            scApp: nil,
            bucket: bucket,
            isActive: isActive
        )
    }

}
