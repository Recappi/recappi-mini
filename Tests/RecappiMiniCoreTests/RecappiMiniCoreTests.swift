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

    func testCloudRecordingJobsRequestUsesRecordingScope() throws {
        let client = RecappiAPIClient(origin: "https://recordmeet.ing", bearerToken: "token_123")
        let request = try client.makeRequest(
            path: "/api/recordings/rec_123/jobs",
            queryItems: [URLQueryItem(name: "limit", value: "10")]
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://recordmeet.ing/api/recordings/rec_123/jobs?limit=10"
        )
    }

    func testCloudRecordingWebURLUsesBackendOrigin() throws {
        let url = try XCTUnwrap(
            cloudRecordingWebURL(
                recordingID: "84adb431-a50a-4432-95a0-d879a956df49",
                backendBaseURL: "https://recordmeet.ing/"
            )
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://recordmeet.ing/recordings/84adb431-a50a-4432-95a0-d879a956df49"
        )
    }

    func testCloudRecordingWebURLDropsBackendPathQueryAndFragment() throws {
        let url = try XCTUnwrap(
            cloudRecordingWebURL(
                recordingID: "rec_123",
                backendBaseURL: "https://staging.recordmeet.ing/api?foo=bar#cloud"
            )
        )

        XCTAssertEqual(url.absoluteString, "https://staging.recordmeet.ing/recordings/rec_123")
    }

    func testRecordingJobsResponseDecodesLatestJobState() throws {
        let data = """
        {
          "items": [
            {
              "id": "job_123",
              "recordingId": "rec_123",
              "userId": "user_123",
              "provider": "gemini",
              "model": "gemini-2.5-flash",
              "language": "en",
              "status": "running",
              "error": null,
              "prompt": null,
              "attempts": 1,
              "enqueuedAt": 1777460000000,
              "startedAt": 1777460001000,
              "finishedAt": null,
              "transcriptId": null
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RecordingJobsResponse.self, from: data)

        XCTAssertEqual(response.items.first?.id, "job_123")
        XCTAssertEqual(response.items.first?.status, .running)
        XCTAssertTrue(response.items.first?.status.isActive == true)
    }

    func testRecordingJobsResponseDecodesFailedJobStateAndError() throws {
        let data = """
        {
          "items": [
            {
              "id": "job_failed",
              "recordingId": "rec_123",
              "userId": "user_123",
              "provider": "gemini",
              "model": "gemini-2.5-flash",
              "language": "en",
              "status": "failed",
              "error": "ASR provider returned an empty transcript.",
              "prompt": null,
              "attempts": 2,
              "enqueuedAt": 1777460000000,
              "startedAt": 1777460001000,
              "finishedAt": 1777460009000,
              "transcriptId": null
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RecordingJobsResponse.self, from: data)
        let job = try XCTUnwrap(response.items.first)

        XCTAssertEqual(job.id, "job_failed")
        XCTAssertEqual(job.status, .failed)
        XCTAssertFalse(job.status.isActive)
        XCTAssertEqual(job.error, "ASR provider returned an empty transcript.")
    }

    func testFailedRecordingPlaceholderJobMakesRecordingFailureVisible() {
        let job = TranscriptionJob.failedRecordingPlaceholder(recordingID: "rec_123")

        XCTAssertEqual(job.status, .failed)
        XCTAssertTrue(job.isFailedRecordingPlaceholder)
        XCTAssertEqual(job.provider, "Recappi Cloud")
        XCTAssertEqual(job.model, "Recording processing")
        XCTAssertNotNil(job.error)
    }

    func testCloudLibraryLatestTranscriptRequestDoesNotUseActiveTranscriptIdAsJobId() throws {
        let client = RecappiAPIClient(origin: "https://recordmeet.ing", bearerToken: "token_123")
        let request = try client.makeRequest(path: "/api/recordings/rec_123/transcript")

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://recordmeet.ing/api/recordings/rec_123/transcript"
        )
    }

    func testTranscriptionRequestBodyCanForceFreshRun() throws {
        let body = try JSONEncoder().encode(
            StartTranscriptionRequest(
                provider: "gemini",
                language: "en",
                force: true,
                prompt: "Run a fresh transcription pass with the default Recappi instructions.",
                summarize: false
            )
        )
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]

        XCTAssertEqual(json?["provider"] as? String, "gemini")
        XCTAssertEqual(json?["language"] as? String, "en")
        XCTAssertEqual(json?["force"] as? Bool, true)
        XCTAssertEqual(json?["summarize"] as? Bool, false)
        XCTAssertEqual(
            json?["prompt"] as? String,
            "Run a fresh transcription pass with the default Recappi instructions."
        )
    }

    func testSummaryStartResponseDecodesQueuedState() throws {
        let data = """
        {
          "transcriptId": "transcript_123",
          "summaryStatus": "queued"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(StartSummaryResponse.self, from: data)

        XCTAssertEqual(response.transcriptId, "transcript_123")
        XCTAssertEqual(response.summaryStatus, "queued")
    }

    func testTranscriptResponseDecodesBackendSegmentsJSON() throws {
        let data = """
        {
          "id": "tr_123",
          "text": "Hello there.\\nWelcome back.",
          "summary": "Two people greeted each other.",
          "actionItemsJson": "[\\"Follow up with the launch notes.\\",\\"  \\"]",
          "segmentsJson": "[{\\"start\\":0,\\"end\\":1300,\\"text\\":\\"Hello there.\\",\\"speaker\\":\\"Speaker 1\\"},{\\"start\\":1300,\\"end\\":2500,\\"text\\":\\"Welcome back.\\"}]"
        }
        """.data(using: .utf8)!

        let transcript = try JSONDecoder().decode(TranscriptResponse.self, from: data)

        XCTAssertEqual(transcript.id, "tr_123")
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].startMs, 0)
        XCTAssertEqual(transcript.segments[0].endMs, 1_300)
        XCTAssertEqual(transcript.segments[0].speaker, "Speaker 1")
        XCTAssertEqual(transcript.segments[1].text, "Welcome back.")
        XCTAssertEqual(transcript.summary, "Two people greeted each other.")
        XCTAssertEqual(transcript.actionItems, ["Follow up with the launch notes."])
    }

    func testTranscriptResponseDecodesSummaryJSONInsights() throws {
        let data = #"""
        {
          "id": "tr_123",
          "text": "Transcript body.",
          "summaryJson": "{\"tldr\":\"Gallery work is ready for review.\",\"keyPoints\":[\"Use a large preview waterfall.\"],\"topics\":[\"Gallery\"],\"decisions\":[\"Keep clone out of scope.\"],\"actionItems\":[{\"what\":\"Review the Gallery waterfall layout.\",\"who\":\"Peng\"},{\"what\":\"  \"}],\"quotes\":[{\"speaker\":\"Peng\",\"text\":\"Make the waterfall feel worth clicking.\"}]}"
        }
        """#.data(using: .utf8)!

        let transcript = try JSONDecoder().decode(TranscriptResponse.self, from: data)

        XCTAssertEqual(transcript.summary, "Gallery work is ready for review.")
        XCTAssertEqual(transcript.actionItems, ["Peng — Review the Gallery waterfall layout."])
        XCTAssertEqual(transcript.summaryInsights?.keyPoints, ["Use a large preview waterfall."])
        XCTAssertEqual(transcript.summaryInsights?.topics, ["Gallery"])
        XCTAssertEqual(transcript.summaryInsights?.decisions, ["Keep clone out of scope."])
        XCTAssertEqual(
            transcript.summaryInsights?.quoteTexts,
            ["Peng: \"Make the waterfall feel worth clicking.\""]
        )
    }

    func testTranscriptResponseKeepsUnavailableSummaryAndActionItemsNil() throws {
        let data = """
        {
          "id": "tr_123",
          "text": "Transcript only."
        }
        """.data(using: .utf8)!

        let transcript = try JSONDecoder().decode(TranscriptResponse.self, from: data)

        XCTAssertNil(transcript.summary)
        XCTAssertNil(transcript.actionItems)
    }

    func testTranscriptResponseBuildsTextWhenOnlySegmentsArePresent() throws {
        let data = """
        {
          "id": "tr_123",
          "segments": [
            { "startMs": 0, "endMs": 900, "text": "First line." },
            { "startMs": 900, "endMs": 1800, "text": "Second line." }
          ]
        }
        """.data(using: .utf8)!

        let transcript = try JSONDecoder().decode(TranscriptResponse.self, from: data)

        XCTAssertEqual(transcript.text, "First line.\nSecond line.")
        XCTAssertEqual(transcript.segments.count, 2)
    }

    func testTranscriptResponseNormalizesSecondBasedSegmentsForPlayback() throws {
        let data = """
        {
          "id": "tr_123",
          "segmentsJson": "[{\\"start\\":62,\\"end\\":68,\\"text\\":\\"A timed line.\\"},{\\"start\\":68,\\"end\\":73,\\"text\\":\\"Another line.\\"}]"
        }
        """.data(using: .utf8)!

        let transcript = try JSONDecoder().decode(TranscriptResponse.self, from: data)

        XCTAssertEqual(transcript.segments[0].startMs, 62_000)
        XCTAssertEqual(transcript.segments[0].endMs, 68_000)
        XCTAssertEqual(transcript.segments[1].startMs, 68_000)
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

    func testBillingStatusDecodingAcceptsUnlimitedTier() throws {
        let data = """
        {
          "tier": "unlimited",
          "periodStart": "2026-04-01T00:00:00.000Z",
          "periodEnd": null,
          "storageBytes": 162472166,
          "storageCapBytes": null,
          "minutesUsed": 131,
          "minutesCap": null,
          "isOverStorage": true,
          "isOverMinutes": true
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(BillingStatus.self, from: data)

        XCTAssertEqual(status.tier, .unlimited)
        XCTAssertEqual(status.tier.displayName, "Unlimited")
        XCTAssertEqual(status.storageCapBytes, 0)
        XCTAssertEqual(status.minutesCap, 0)
        XCTAssertTrue(status.hasUnlimitedStorage)
        XCTAssertTrue(status.hasUnlimitedMinutes)
        XCTAssertFalse(status.effectiveIsOverStorage)
        XCTAssertFalse(status.effectiveIsOverMinutes)
        XCTAssertFalse(status.effectiveIsOverAnyLimit)
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
          "nextCursor": "next_456",
          "totalCount": 37
        }
        """.data(using: .utf8)!

        let page = try JSONDecoder().decode(CloudRecordingsPage.self, from: data)

        XCTAssertEqual(page.nextCursor, "next_456")
        XCTAssertEqual(page.totalCount, 37)
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

    func testTranscriptResponseDecodesSummaryTitleFromSummaryJson() throws {
        let data = """
        {
          "id": "tr_123",
          "text": "Design review transcript.",
          "summaryJson": "{\\"title\\":\\"Design review with iOS team\\",\\"tldr\\":\\"The team reviewed the next app polish pass.\\"}",
          "segments": []
        }
        """.data(using: .utf8)!

        let transcript = try JSONDecoder().decode(TranscriptResponse.self, from: data)

        XCTAssertEqual(transcript.summaryInsights?.title, "Design review with iOS team")
        XCTAssertEqual(transcript.summary, "The team reviewed the next app polish pass.")
    }

    func testTranscriptResponseKeepsTitleOnlySummaryInsights() throws {
        let data = """
        {
          "id": "tr_124",
          "text": "Quick transcript.",
          "summaryJson": "{\\"title\\":\\"Customer research sync\\"}",
          "segments": []
        }
        """.data(using: .utf8)!

        let transcript = try JSONDecoder().decode(TranscriptResponse.self, from: data)

        XCTAssertEqual(transcript.summaryInsights?.title, "Customer research sync")
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

    func testCloudRecordingMergesCachedDetailForSWRListRefresh() {
        let cached = CloudRecording(
            id: "rec_123",
            userId: "user_123",
            title: "Cached title",
            summaryTitle: "Cached summary",
            sourceTitle: "Cached source",
            sourceAppName: "Arc",
            sourceAppBundleID: "company.thebrowser.Browser",
            r2Key: "recordings/user_123/rec_123.wav",
            r2UploadId: nil,
            status: .ready,
            sizeBytes: 41_700_000,
            durationMs: 1_282_000,
            sampleRate: 16_000,
            channels: 1,
            contentType: "audio/wav",
            activeTranscriptId: "tr_cached",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let refreshedListItem = CloudRecording(
            id: "rec_123",
            userId: "user_123",
            title: "Server title",
            summaryTitle: nil,
            sourceTitle: nil,
            sourceAppName: nil,
            sourceAppBundleID: nil,
            r2Key: nil,
            r2UploadId: nil,
            status: .failed,
            sizeBytes: nil,
            durationMs: nil,
            sampleRate: nil,
            channels: nil,
            contentType: nil,
            activeTranscriptId: nil,
            createdAt: nil,
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        let merged = refreshedListItem.mergingCachedDetail(from: cached)

        XCTAssertEqual(merged.status, .failed)
        XCTAssertEqual(merged.title, "Server title")
        XCTAssertEqual(merged.summaryTitle, "Cached summary")
        XCTAssertEqual(merged.sourceAppName, "Arc")
        XCTAssertEqual(merged.sizeBytes, 41_700_000)
        XCTAssertEqual(merged.durationMs, 1_282_000)
        XCTAssertEqual(merged.sampleRate, 16_000)
        XCTAssertEqual(merged.channels, 1)
        XCTAssertEqual(merged.contentType, "audio/wav")
        XCTAssertEqual(merged.activeTranscriptId, "tr_cached")
        XCTAssertEqual(merged.updatedAt, Date(timeIntervalSince1970: 300))
    }

    func testCloudRecordingDisplayStatusPrefersLatestActiveOrFailedJob() {
        XCTAssertEqual(
            CloudRecordingDisplayStatus.resolve(recordingStatus: .ready, latestJobStatus: .running),
            .transcription(.running)
        )
        XCTAssertEqual(
            CloudRecordingDisplayStatus.resolve(recordingStatus: .ready, latestJobStatus: .failed),
            .transcription(.failed)
        )
        XCTAssertEqual(
            CloudRecordingDisplayStatus.resolve(recordingStatus: .ready, latestJobStatus: .succeeded),
            .recording(.ready)
        )
    }

    @MainActor
    func testCloudLibraryUpsertsLocalProcessingRecording() {
        let store = CloudLibraryStore()
        let recording = CloudRecording(
            id: "rec_processing",
            userId: nil,
            title: "Live meeting",
            summaryTitle: nil,
            sourceTitle: "Design sync",
            sourceAppName: "Google Meet",
            sourceAppBundleID: "com.google.Chrome",
            r2Key: "recordings/user/rec_processing.wav",
            r2UploadId: nil,
            status: .uploading,
            sizeBytes: nil,
            durationMs: 120_000,
            sampleRate: nil,
            channels: nil,
            contentType: nil,
            activeTranscriptId: nil,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let job = TranscriptionJob(
            id: "job_processing",
            status: .running,
            transcriptId: nil,
            provider: "Recappi Cloud",
            model: "Transcription",
            language: nil,
            prompt: nil,
            error: nil,
            attempts: nil,
            enqueuedAt: 1_000,
            startedAt: 1_001,
            finishedAt: nil
        )

        store.upsertLocalProcessingRecording(recording, latestJob: job)

        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.selectedRecordingID, "rec_processing")
        XCTAssertEqual(store.recordings.first?.id, "rec_processing")
        XCTAssertEqual(store.recordings.first?.status, .uploading)
        XCTAssertEqual(store.transcriptionJobsByRecordingID["rec_processing"]?.first?.status, .running)
    }

    func testCloudLibrarySnapshotRoundTripsLightweightData() throws {
        let recording = try JSONDecoder().decode(
            CloudRecording.self,
            from: """
            {
              "id": "rec_123",
              "userId": "user_123",
              "title": "Weekly sync",
              "summaryTitle": "Product review",
              "sourceAppName": "Google Chrome",
              "sourceAppBundleID": "com.google.Chrome",
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
            """.data(using: .utf8)!
        )
        let transcript = try JSONDecoder().decode(
            TranscriptResponse.self,
            from: """
            {
              "id": "tr_123",
              "text": "Hello from cache.",
              "summary": "Cached summary.",
              "summaryJson": "{\\"title\\":\\"Cached product review\\",\\"tldr\\":\\"Cached TLDR.\\",\\"keyPoints\\":[\\"Cached key point.\\"]}",
              "actionItemsJson": "[\\"Ship the cache fixture.\\"]",
              "segments": [
                { "startMs": 0, "endMs": 1200, "text": "Hello from cache.", "speaker": "Peng" }
              ]
            }
            """.data(using: .utf8)!
        )
        let billing = try JSONDecoder().decode(
            BillingStatus.self,
            from: """
            {
              "tier": "pro",
              "periodStart": "2026-04-01T00:00:00.000Z",
              "periodEnd": "2026-05-01T00:00:00.000Z",
              "storageBytes": 1024,
              "storageCapBytes": 2048,
              "minutesUsed": 42,
              "minutesCap": 120,
              "isOverStorage": false,
              "isOverMinutes": false
            }
            """.data(using: .utf8)!
        )
        let job = try JSONDecoder().decode(
            TranscriptionJob.self,
            from: """
            {
              "id": "job_123",
              "status": "queued",
              "transcriptId": null,
              "provider": "gemini",
              "model": "gemini-3-flash-preview",
              "language": "en",
              "prompt": null,
              "error": null,
              "attempts": 0,
              "enqueuedAt": 1776957994
            }
            """.data(using: .utf8)!
        )

        let snapshot = CloudLibrarySnapshot(
            userId: "user_123",
            backendOrigin: "https://recordmeet.ing",
            savedAt: Date(timeIntervalSince1970: 1_776_957_994),
            recordings: [recording],
            nextCursor: "next_456",
            selectedRecordingID: "rec_123",
            billingStatus: billing,
            transcriptCache: ["rec_123": transcript],
            transcriptionJobsByRecordingID: ["rec_123": [job]]
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CloudLibrarySnapshot.self, from: encoded)

        XCTAssertTrue(decoded.matches(userId: "user_123", backendOrigin: "https://recordmeet.ing"))
        XCTAssertEqual(decoded.decodedRecordings.first?.summaryTitle, "Product review")
        XCTAssertEqual(decoded.decodedRecordings.first?.status, .ready)
        XCTAssertEqual(decoded.decodedBillingStatus?.tier, .pro)
        XCTAssertEqual(decoded.decodedTranscripts["rec_123"]?.summary, "Cached summary.")
        XCTAssertEqual(decoded.decodedTranscripts["rec_123"]?.summaryInsights?.title, "Cached product review")
        XCTAssertEqual(decoded.decodedTranscripts["rec_123"]?.summaryInsights?.keyPoints, ["Cached key point."])
        XCTAssertEqual(decoded.decodedTranscripts["rec_123"]?.actionItems, ["Ship the cache fixture."])
        XCTAssertEqual(decoded.decodedTranscripts["rec_123"]?.segments.first?.speaker, "Peng")
        XCTAssertEqual(decoded.decodedTranscriptionJobsByRecordingID["rec_123"]?.first?.id, "job_123")
        XCTAssertEqual(decoded.decodedTranscriptionJobsByRecordingID["rec_123"]?.first?.status, .queued)
        XCTAssertEqual(decoded.nextCursor, "next_456")
        XCTAssertEqual(decoded.selectedRecordingID, "rec_123")
    }

    func testCloudLibraryCachePartitionsByUserAndOrigin() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let recording = try JSONDecoder().decode(
            CloudRecording.self,
            from: """
            {
              "id": "rec_123",
              "userId": "user_123",
              "title": "Cached recording",
              "status": "ready"
            }
            """.data(using: .utf8)!
        )
        let cache = CloudLibraryCache(directoryURL: temp)
        let snapshot = CloudLibrarySnapshot(
            userId: "user_123",
            backendOrigin: "https://recordmeet.ing",
            savedAt: Date(timeIntervalSince1970: 1_776_957_994),
            recordings: [recording],
            nextCursor: nil,
            selectedRecordingID: "rec_123",
            billingStatus: nil,
            transcriptCache: [:]
        )

        await cache.saveSnapshot(snapshot)

        let loaded = await cache.loadSnapshot(userId: "user_123", backendOrigin: "https://recordmeet.ing")
        XCTAssertEqual(loaded?.decodedRecordings.first?.id, "rec_123")

        let otherUser = await cache.loadSnapshot(userId: "user_456", backendOrigin: "https://recordmeet.ing")
        XCTAssertNil(otherUser)

        let otherOrigin = await cache.loadSnapshot(userId: "user_123", backendOrigin: "https://staging.recordmeet.ing")
        XCTAssertNil(otherOrigin)
    }

    func testCloudLibraryCachePersistsTranscriptFreshnessAnchorInSQLite() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let recording = try JSONDecoder().decode(
            CloudRecording.self,
            from: """
            {
              "id": "rec_123",
              "userId": "user_123",
              "title": "Cached recording",
              "status": "ready",
              "activeTranscriptId": "tr_123",
              "updatedAt": "2026-04-24T08:03:00.000Z"
            }
            """.data(using: .utf8)!
        )
        let transcript = try JSONDecoder().decode(
            TranscriptResponse.self,
            from: """
            {
              "id": "tr_123",
              "text": "Hello from cache.",
              "summary": "Cached summary.",
              "segments": []
            }
            """.data(using: .utf8)!
        )
        let anchor = Date(timeIntervalSince1970: 1_776_958_013.234)
        let cache = CloudLibraryCache(directoryURL: temp)
        let snapshot = CloudLibrarySnapshot(
            userId: "user_123",
            backendOrigin: "https://recordmeet.ing",
            savedAt: Date(timeIntervalSince1970: 1_776_957_994),
            recordings: [recording],
            nextCursor: nil,
            selectedRecordingID: "rec_123",
            billingStatus: nil,
            transcriptCache: ["rec_123": transcript],
            transcriptCacheRecordingUpdatedAt: ["rec_123": anchor]
        )

        await cache.saveSnapshot(snapshot)

        let loadedSnapshot = await cache.loadSnapshot(userId: "user_123", backendOrigin: "https://recordmeet.ing")
        let loaded = try XCTUnwrap(loadedSnapshot)
        XCTAssertEqual(loaded.decodedTranscripts["rec_123"]?.id, "tr_123")
        XCTAssertEqual(
            try XCTUnwrap(loaded.decodedTranscriptCacheRecordingUpdatedAt["rec_123"]).timeIntervalSince1970,
            anchor.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("cloud-cache.sqlite3").path))
    }

    func testCloudLibraryCacheMigratesLegacyJSONSnapshotIntoSQLite() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let recording = try JSONDecoder().decode(
            CloudRecording.self,
            from: """
            {
              "id": "rec_legacy",
              "userId": "user_123",
              "title": "Legacy cached recording",
              "status": "ready",
              "activeTranscriptId": "tr_legacy",
              "updatedAt": "2026-04-24T08:03:00.000Z"
            }
            """.data(using: .utf8)!
        )
        let transcript = try JSONDecoder().decode(
            TranscriptResponse.self,
            from: """
            {
              "id": "tr_legacy",
              "text": "Legacy transcript.",
              "summaryJson": "{\\"tldr\\":\\"Legacy TLDR.\\"}",
              "segments": []
            }
            """.data(using: .utf8)!
        )
        let job = try JSONDecoder().decode(
            TranscriptionJob.self,
            from: """
            {
              "id": "job_legacy",
              "status": "succeeded",
              "transcriptId": "tr_legacy",
              "provider": "gemini",
              "model": "gemini-3-flash-preview"
            }
            """.data(using: .utf8)!
        )
        let anchor = Date(timeIntervalSince1970: 1_776_958_013.456)
        let snapshot = CloudLibrarySnapshot(
            userId: "user_123",
            backendOrigin: "https://recordmeet.ing",
            savedAt: Date(timeIntervalSince1970: 1_776_957_994),
            recordings: [recording],
            nextCursor: "next_legacy",
            selectedRecordingID: "rec_legacy",
            billingStatus: nil,
            transcriptCache: ["rec_legacy": transcript],
            transcriptionJobsByRecordingID: ["rec_legacy": [job]],
            transcriptCacheRecordingUpdatedAt: ["rec_legacy": anchor]
        )
        let legacyURL = temp.appendingPathComponent(
            CloudLibraryCache.cacheFilename(userId: "user_123", backendOrigin: "https://recordmeet.ing")
        )
        try JSONEncoder().encode(snapshot).write(to: legacyURL)

        let cache = CloudLibraryCache(directoryURL: temp)
        let migratedSnapshot = await cache.loadSnapshot(userId: "user_123", backendOrigin: "https://recordmeet.ing")
        let migrated = try XCTUnwrap(migratedSnapshot)
        XCTAssertEqual(migrated.decodedRecordings.first?.id, "rec_legacy")
        XCTAssertEqual(migrated.decodedTranscripts["rec_legacy"]?.summary, "Legacy TLDR.")
        XCTAssertEqual(migrated.decodedTranscriptionJobsByRecordingID["rec_legacy"]?.first?.id, "job_legacy")
        XCTAssertEqual(migrated.decodedTranscriptCacheRecordingUpdatedAt["rec_legacy"], anchor)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("cloud-cache.sqlite3").path))

        try FileManager.default.removeItem(at: legacyURL)
        let loadedFromSQLiteSnapshot = await cache.loadSnapshot(userId: "user_123", backendOrigin: "https://recordmeet.ing")
        let loadedFromSQLite = try XCTUnwrap(loadedFromSQLiteSnapshot)
        XCTAssertEqual(loadedFromSQLite.selectedRecordingID, "rec_legacy")
        XCTAssertEqual(loadedFromSQLite.nextCursor, "next_legacy")
        XCTAssertEqual(loadedFromSQLite.decodedTranscripts["rec_legacy"]?.id, "tr_legacy")
        XCTAssertEqual(loadedFromSQLite.decodedTranscriptCacheRecordingUpdatedAt["rec_legacy"], anchor)
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

    func testRecordingStoreLoadsSavedTranscriptBody() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try RecordingStore.saveTranscript("Hello from Recappi.", in: temp)

        XCTAssertEqual(RecordingStore.loadTranscript(in: temp), "Hello from Recappi.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("transcript.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("transcription.md").path))
    }

    func testRecordingStoreRemovesLegacyTranscriptionAliasWhenSavingTranscript() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let legacyAlias = temp.appendingPathComponent("transcription.md")
        try "# Transcription\n\nOld duplicate alias.\n".write(to: legacyAlias, atomically: true, encoding: .utf8)

        try RecordingStore.saveTranscript("Canonical transcript.", in: temp)

        XCTAssertEqual(RecordingStore.loadTranscript(in: temp), "Canonical transcript.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("transcript.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyAlias.path))
    }

    func testRecordingStoreSavesReadableTranscriptSummaryArtifacts() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let data = """
        {
          "id": "tr_123",
          "text": "Peng: Ship the local cache artifacts.",
          "segments": [],
          "summaryJson": "{\\"tldr\\":\\"Local folders need agent-readable artifacts.\\",\\"keyPoints\\":[\\"Write transcript and summary sidecars.\\"],\\"topics\\":[\\"Agent handoff\\"],\\"decisions\\":[\\"Expose markdown files in synced folders.\\"],\\"actionItems\\":[{\\"who\\":\\"Codex\\",\\"what\\":\\"Add summary.md and transcript.md.\\"}],\\"quotes\\":[{\\"speaker\\":\\"Peng\\",\\"text\\":\\"暴露文件才方便让agent读\\"}]}"
        }
        """.data(using: .utf8)!
        let transcript = try JSONDecoder().decode(TranscriptResponse.self, from: data)

        try RecordingStore.saveTranscriptArtifacts(transcript, in: temp)

        let transcriptText = try String(contentsOf: RecordingStore.transcriptFileURL(in: temp), encoding: .utf8)
        let summaryText = try String(contentsOf: RecordingStore.summaryFileURL(in: temp), encoding: .utf8)
        let actionItemsText = try String(contentsOf: RecordingStore.actionItemsFileURL(in: temp), encoding: .utf8)

        XCTAssertTrue(transcriptText.contains("# Transcript"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("transcription.md").path))
        XCTAssertTrue(summaryText.contains("Local folders need agent-readable artifacts."))
        XCTAssertTrue(summaryText.contains("## Key Points"))
        XCTAssertTrue(actionItemsText.contains("Codex — Add summary.md and transcript.md."))
    }

    func testSessionProcessorReusesCompletedRemoteManifest() {
        var manifest = RemoteSessionManifest.stage("startingTranscription")
        manifest.recordingId = " rec_123 "
        manifest.jobId = " job_123 "

        XCTAssertEqual(SessionProcessor.reusableRecordingID(in: manifest), "rec_123")
        XCTAssertEqual(SessionProcessor.reusableJobID(in: manifest), "job_123")
        XCTAssertNil(SessionProcessor.reusableTranscriptID(in: manifest))

        manifest.transcriptId = " tr_123 "
        XCTAssertEqual(SessionProcessor.reusableTranscriptID(in: manifest), "tr_123")

        manifest.stage = "transcriptionFailed"
        XCTAssertEqual(SessionProcessor.reusableRecordingID(in: manifest), "rec_123")
        XCTAssertNil(SessionProcessor.reusableJobID(in: manifest))
        XCTAssertNil(SessionProcessor.reusableTranscriptID(in: manifest))
    }

    func testCloudLibraryIndexesLocalSessionsByRemoteRecordingID() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let older = temp.appendingPathComponent("2026-04-23_110000", isDirectory: true)
        let newer = temp.appendingPathComponent("2026-04-23_120000", isDirectory: true)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        var olderManifest = RemoteSessionManifest.stage("done")
        olderManifest.recordingId = "rec_123"
        _ = RecordingStore.saveRemoteManifest(olderManifest, in: older)

        var newerManifest = RemoteSessionManifest.stage("done")
        newerManifest.recordingId = "rec_123"
        _ = RecordingStore.saveRemoteManifest(newerManifest, in: newer)

        let links = CloudLibraryStore.localSessionLinks(in: temp)

        XCTAssertEqual(
            links["rec_123"]?.standardizedFileURL,
            newer.standardizedFileURL
        )
    }

    func testFloatingPanelHitTestMatchesVisiblePillOnly() {
        let bounds = NSRect(
            x: 0,
            y: 0,
            width: DT.panelWidth + PillShellView.shadowMargin * 2,
            height: 96
        )
        let visibleRect = PillShellView.visiblePillRect(in: bounds)

        XCTAssertFalse(PillShellView.visiblePillContains(NSPoint(x: 4, y: bounds.midY), in: bounds))
        XCTAssertFalse(PillShellView.visiblePillContains(NSPoint(x: visibleRect.minX + 1, y: visibleRect.minY + 1), in: bounds))
        XCTAssertTrue(PillShellView.visiblePillContains(NSPoint(x: visibleRect.midX, y: visibleRect.midY), in: bounds))
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

    func testPlaybackWaveformExtractorUsesAudioAmplitudeShape() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let url = temp.appendingPathComponent("shape.caf")
        try writeAmplitudeSteps(
            to: url,
            amplitudes: [0.12, 0.82, 0.28, 0.64],
            sampleRate: 16_000,
            frequency: 440
        )

        let peaks = try PlaybackWaveformExtractor.peaks(from: url, bucketCount: 4)

        XCTAssertEqual(peaks.count, 4)
        XCTAssertGreaterThan(peaks[1], peaks[0] + 0.35)
        XCTAssertGreaterThan(peaks[3], peaks[2] + 0.18)
        XCTAssertGreaterThan(peaks[1], peaks[3])
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

    func testBundleCollapserCanonicalizesArcHelpersCaseInsensitively() {
        XCTAssertEqual(
            BundleCollapser.parent(of: "company.thebrowser.browser.Helper.Renderer"),
            "company.thebrowser.Browser"
        )
        XCTAssertTrue(BundleCollapser.matches(
            "company.thebrowser.browser.Helper.Renderer",
            selected: "company.thebrowser.Browser"
        ))
        XCTAssertEqual(
            BundleCollapser.browserDisplayName(for: "company.thebrowser.browser.Helper.Renderer", fallback: "Arc Helper"),
            "Arc"
        )
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

    func testBrowserMeetingDetectorSupportsArc() {
        XCTAssertTrue(BrowserMeetingDetector.supports(bundleID: "company.thebrowser.Browser"))
        XCTAssertTrue(BrowserMeetingDetector.supports(bundleID: "company.thebrowser.browser.Helper.Renderer"))
    }

    func testBrowserMeetingDetectorFindsMeetingTabAmongArcTabs() {
        let output = """
        https://linear.app/recappi\tIssue tracker
        https://meet.google.com/crh-homj-oub\tTeam sync - Google Meet
        https://www.youtube.com/watch?v=abc\tMusic
        """

        XCTAssertEqual(
            BrowserMeetingDetector.meetingSuggestion(fromScriptOutput: output, browserName: "Arc"),
            "Google Meet in Arc"
        )
    }

    func testBrowserMeetingDetectorKeepsLegacyTwoLineOutputCompatible() {
        let output = """
        https://teams.microsoft.com/l/meetup-join/123
        Weekly sync | Microsoft Teams
        """

        let contexts = BrowserTabContext.parseMany(output: output)
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts.first?.urlString, "https://teams.microsoft.com/l/meetup-join/123")
        XCTAssertEqual(contexts.first?.pageTitle, "Weekly sync | Microsoft Teams")
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

    private func writeAmplitudeSteps(
        to url: URL,
        amplitudes: [Float],
        sampleRate: Double,
        frequency: Double
    ) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            XCTFail("Failed to create amplitude-step format")
            return
        }

        let framesPerStep = Int(sampleRate * 0.08)
        let frameCount = max(framesPerStep * amplitudes.count, 1)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ),
        let channelData = buffer.floatChannelData else {
            XCTFail("Failed to create amplitude-step buffer")
            return
        }

        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<frameCount {
            let step = min(frame / max(framesPerStep, 1), max(amplitudes.count - 1, 0))
            let amplitude = amplitudes[step]
            channelData[0][frame] = amplitude * Float(sin(2 * .pi * frequency * Double(frame) / sampleRate))
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

    // MARK: - CloudLibraryStore.shouldFlagNewerVersion

    func test_shouldFlagNewerVersion_returnsFalse_whenFreshIdIsNil() {
        XCTAssertFalse(CloudLibraryStore.shouldFlagNewerVersion(
            cachedActiveTranscriptId: "trans_v1",
            freshActiveTranscriptId: nil,
            cachedTranscriptResponseId: "trans_v1"
        ))
    }

    func test_shouldFlagNewerVersion_returnsFalse_whenCachedIdIsNil() {
        // First load / no prior cache: don't preemptively scare the user.
        XCTAssertFalse(CloudLibraryStore.shouldFlagNewerVersion(
            cachedActiveTranscriptId: nil,
            freshActiveTranscriptId: "trans_v1",
            cachedTranscriptResponseId: nil
        ))
    }

    func test_shouldFlagNewerVersion_returnsFalse_whenIdsMatch() {
        XCTAssertFalse(CloudLibraryStore.shouldFlagNewerVersion(
            cachedActiveTranscriptId: "trans_v1",
            freshActiveTranscriptId: "trans_v1",
            cachedTranscriptResponseId: "trans_v1"
        ))
    }

    func test_shouldFlagNewerVersion_returnsTrue_whenCloudHasNewerTranscript() {
        XCTAssertTrue(CloudLibraryStore.shouldFlagNewerVersion(
            cachedActiveTranscriptId: "trans_v1",
            freshActiveTranscriptId: "trans_v2",
            cachedTranscriptResponseId: "trans_v1"
        ))
    }

    func test_shouldFlagNewerVersion_returnsFalse_whenLocalCacheAlreadyHasNewerTranscript() {
        // Local retranscribe just finished: transcriptCache holds trans_v2,
        // recording.activeTranscriptId still pointed at trans_v1 in our cache,
        // and cloud detail catches up to trans_v2. Don't show the banner —
        // the user is already viewing the latest content.
        XCTAssertFalse(CloudLibraryStore.shouldFlagNewerVersion(
            cachedActiveTranscriptId: "trans_v1",
            freshActiveTranscriptId: "trans_v2",
            cachedTranscriptResponseId: "trans_v2"
        ))
    }

    func test_shouldFlagNewerVersion_returnsTrue_whenTranscriptCacheStillOnOldId() {
        // Cloud advanced past local. transcriptCache happens to hold the old id.
        XCTAssertTrue(CloudLibraryStore.shouldFlagNewerVersion(
            cachedActiveTranscriptId: "trans_v1",
            freshActiveTranscriptId: "trans_v2",
            cachedTranscriptResponseId: "trans_old_unrelated"
        ))
    }

    func test_shouldFlagNewerVersion_returnsTrue_whenTranscriptCacheIsAbsent() {
        // We already had this recording in our list (metadata snapshot at
        // trans_v1) but never loaded the transcript content. Cloud has
        // since advanced to trans_v2. The metadata diff alone justifies
        // flagging — when the user opens the detail they would otherwise
        // see no banner and no warning that the recording moved on.
        XCTAssertTrue(CloudLibraryStore.shouldFlagNewerVersion(
            cachedActiveTranscriptId: "trans_v1",
            freshActiveTranscriptId: "trans_v2",
            cachedTranscriptResponseId: nil
        ))
    }

    // MARK: - v1.0.36 → v1.0.37 expanded staleness detection

    func test_shouldFlagNewerVersion_returnsTrue_whenMetadataConsistentButLocalContentStale() {
        // The peng-xiao bug: list/detail metadata both show "trans_v2" so
        // there is no metadata diff, but the local transcript cache still
        // points at the previous transcript "trans_v1". User is staring at
        // outdated content with no banner. v1.0.37 flags this.
        XCTAssertTrue(CloudLibraryStore.shouldFlagNewerVersion(
            cachedActiveTranscriptId: "trans_v2",
            freshActiveTranscriptId: "trans_v2",
            cachedTranscriptResponseId: "trans_v1"
        ))
    }

    func test_shouldFlagNewerVersion_returnsFalse_whileTranscriptIsLoading() {
        // While `loadTranscriptForSelection` is in flight we suppress the
        // banner so it does not flash on the normal "select recording"
        // path before content arrives.
        XCTAssertFalse(CloudLibraryStore.shouldFlagNewerVersion(
            cachedActiveTranscriptId: "trans_v1",
            freshActiveTranscriptId: "trans_v2",
            cachedTranscriptResponseId: "trans_v1",
            isTranscriptLoading: true
        ))
    }

    func test_shouldFlagNewerVersion_loadingGuardOverridesContentStaleCase() {
        // Same content-stale shape as
        // `test_shouldFlagNewerVersion_returnsTrue_whenMetadataConsistentButLocalContentStale`
        // but the loader is mid-flight. Suppress.
        XCTAssertFalse(CloudLibraryStore.shouldFlagNewerVersion(
            cachedActiveTranscriptId: "trans_v2",
            freshActiveTranscriptId: "trans_v2",
            cachedTranscriptResponseId: "trans_v1",
            isTranscriptLoading: true
        ))
    }

    // MARK: - CloudLibraryStore.shouldFlagOnUpdatedAtAdvance

    func test_shouldFlagOnUpdatedAtAdvance_returnsTrue_whenFreshIsLater() {
        // The summary-arrived-after-transcribe scenario: same
        // activeTranscriptId, but the recording row was amended later.
        let cached = Date(timeIntervalSinceReferenceDate: 100)
        let fresh = Date(timeIntervalSinceReferenceDate: 200)
        XCTAssertTrue(CloudLibraryStore.shouldFlagOnUpdatedAtAdvance(
            cachedUpdatedAt: cached,
            freshUpdatedAt: fresh
        ))
    }

    func test_shouldFlagOnUpdatedAtAdvance_returnsFalse_whenEqual() {
        // No advancement: server hasn't touched the recording since we
        // cached it. Nothing to surface.
        let date = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertFalse(CloudLibraryStore.shouldFlagOnUpdatedAtAdvance(
            cachedUpdatedAt: date,
            freshUpdatedAt: date
        ))
    }

    func test_shouldFlagOnUpdatedAtAdvance_returnsFalse_whenFreshIsEarlier() {
        // Defensive: clock skew or reordering — never produce a false
        // positive when the cached snapshot somehow looks newer than the
        // remote.
        let cached = Date(timeIntervalSinceReferenceDate: 200)
        let fresh = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertFalse(CloudLibraryStore.shouldFlagOnUpdatedAtAdvance(
            cachedUpdatedAt: cached,
            freshUpdatedAt: fresh
        ))
    }

    func test_shouldFlagOnUpdatedAtAdvance_returnsFalse_whenFreshIsNil() {
        // Server didn't return updatedAt; cannot decide → don't flag.
        let cached = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertFalse(CloudLibraryStore.shouldFlagOnUpdatedAtAdvance(
            cachedUpdatedAt: cached,
            freshUpdatedAt: nil
        ))
    }

    func test_shouldFlagOnUpdatedAtAdvance_returnsFalse_whenCachedIsNil() {
        // First-time view of this recording — no previous timestamp to
        // compare against. The metadata-id checks elsewhere handle the
        // "first load" case; this helper should opt out.
        let fresh = Date(timeIntervalSinceReferenceDate: 200)
        XCTAssertFalse(CloudLibraryStore.shouldFlagOnUpdatedAtAdvance(
            cachedUpdatedAt: nil,
            freshUpdatedAt: fresh
        ))
    }

    // MARK: - CloudLibraryStore.shouldDropForMissingSummary

    private func makeTranscript(summary: String?, hasInsights: Bool) throws -> TranscriptResponse {
        var dict: [String: Any] = [
            "id": "trans-test",
            "text": "hello",
            "segments": [],
        ]
        if let summary {
            dict["summary"] = summary
        }
        if hasInsights {
            dict["summaryInsights"] = [
                "tldr": "tldr-text",
                "summary": NSNull(),
                "keyPoints": ["one"],
                "topics": [],
                "decisions": [],
                "actionItems": [],
                "quotes": [],
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(TranscriptResponse.self, from: data)
    }

    func test_shouldDropForMissingSummary_returnsTrue_whenReadyAndNoSummary() throws {
        // The peng-xiao bug: cache holds a transcript body but no summary,
        // recording is `.ready`, and we have not yet attempted a force
        // refetch this session. The shape-based fallback must drop the
        // cache so the next load picks up the now-summarized body.
        let transcript = try makeTranscript(summary: nil, hasInsights: false)
        XCTAssertTrue(CloudLibraryStore.shouldDropForMissingSummary(
            cachedTranscript: transcript,
            recordingStatus: .ready,
            alreadyAttempted: false
        ))
    }

    func test_shouldDropForMissingSummary_returnsFalse_whenAlreadyAttempted() throws {
        // Once-per-session retry guard: don't hammer the network for
        // recordings that genuinely have no summary.
        let transcript = try makeTranscript(summary: nil, hasInsights: false)
        XCTAssertFalse(CloudLibraryStore.shouldDropForMissingSummary(
            cachedTranscript: transcript,
            recordingStatus: .ready,
            alreadyAttempted: true
        ))
    }

    func test_shouldDropForMissingSummary_returnsFalse_whenSummaryTextPresent() throws {
        let transcript = try makeTranscript(summary: "we shipped it", hasInsights: false)
        XCTAssertFalse(CloudLibraryStore.shouldDropForMissingSummary(
            cachedTranscript: transcript,
            recordingStatus: .ready,
            alreadyAttempted: false
        ))
    }

    func test_shouldDropForMissingSummary_returnsFalse_whenSummaryInsightsPresent() throws {
        // Insights without a top-level summary string still counts as
        // "summary content present" — the UI renders insights directly.
        let transcript = try makeTranscript(summary: nil, hasInsights: true)
        XCTAssertFalse(CloudLibraryStore.shouldDropForMissingSummary(
            cachedTranscript: transcript,
            recordingStatus: .ready,
            alreadyAttempted: false
        ))
    }

    func test_shouldDropForMissingSummary_returnsFalse_whenRecordingNotReady() throws {
        // For a `.failed` recording the backend never produced a transcript
        // job that could ever surface a summary; retrying is wasteful.
        let transcript = try makeTranscript(summary: nil, hasInsights: false)
        XCTAssertFalse(CloudLibraryStore.shouldDropForMissingSummary(
            cachedTranscript: transcript,
            recordingStatus: .failed,
            alreadyAttempted: false
        ))
    }

    func test_shouldDropForMissingSummary_returnsFalse_whenSummaryIsWhitespace() throws {
        // Treat a whitespace-only summary as effectively absent so the
        // recovery path still runs.
        let transcript = try makeTranscript(summary: "   \n  ", hasInsights: false)
        XCTAssertTrue(CloudLibraryStore.shouldDropForMissingSummary(
            cachedTranscript: transcript,
            recordingStatus: .ready,
            alreadyAttempted: false
        ))
    }

    // MARK: - OnboardingState.shouldPresentOnLaunch

    func test_shouldPresentOnLaunch_returnsTrue_onFirstLaunch() {
        XCTAssertTrue(OnboardingState.shouldPresentOnLaunch(
            didComplete: false,
            uiTestModeForcesOnboarding: false,
            uiTestModeSuppressesOnboarding: false
        ))
    }

    func test_shouldPresentOnLaunch_returnsFalse_afterCompletion() {
        XCTAssertFalse(OnboardingState.shouldPresentOnLaunch(
            didComplete: true,
            uiTestModeForcesOnboarding: false,
            uiTestModeSuppressesOnboarding: false
        ))
    }

    func test_shouldPresentOnLaunch_uiTestSuppressTakesPrecedence() {
        // Suppression beats both the persistent flag and the force flag —
        // UI tests need to be able to pin the launch behavior in either
        // direction without depending on the user defaults state of the
        // host machine.
        XCTAssertFalse(OnboardingState.shouldPresentOnLaunch(
            didComplete: false,
            uiTestModeForcesOnboarding: true,
            uiTestModeSuppressesOnboarding: true
        ))
    }

    func test_shouldPresentOnLaunch_uiTestForceOverridesCompletion() {
        XCTAssertTrue(OnboardingState.shouldPresentOnLaunch(
            didComplete: true,
            uiTestModeForcesOnboarding: true,
            uiTestModeSuppressesOnboarding: false
        ))
    }

    /// Smoke fixtures that open the Cloud window on launch
    /// (`RECAPPI_TEST_OPEN_CLOUD_WINDOW=1`) should not be ambushed by
    /// the onboarding window on a CI runner with fresh UserDefaults.
    /// `AppDelegate` derives an implicit suppression in that case and
    /// hands it down to `shouldPresentOnLaunch`; this test pins the
    /// downstream contract: when the suppress flag is `true`, the
    /// function returns `false` regardless of the persisted completion
    /// state.
    func test_shouldPresentOnLaunch_implicitSuppressionFromOpenCloudFixture() {
        XCTAssertFalse(OnboardingState.shouldPresentOnLaunch(
            didComplete: false,
            uiTestModeForcesOnboarding: false,
            uiTestModeSuppressesOnboarding: true
        ))
    }

}
