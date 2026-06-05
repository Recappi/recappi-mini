import AVFoundation
import Combine
import SwiftUI
import XCTest
@testable import RecappiMini

final class RecappiMiniCoreTests: XCTestCase {
    func testLiveCaptionSentenceSplitterSplitsEnglishAndKeepsPendingTail() {
        let segments = LiveCaptionSentenceSplitter.split(
            "If you have a team, pay attention. It is a very important thing. You should pay them too",
            mode: .source
        )

        XCTAssertEqual(
            segments,
            [
                "If you have a team, pay attention.",
                "It is a very important thing.",
                "You should pay them too",
            ]
        )
    }

    func testLiveCaptionSentenceSplitterAvoidsCommonEnglishFalseBoundaries() {
        let segments = LiveCaptionSentenceSplitter.split(
            "Dr. Smith measured 1.5 liters. Then he left.",
            mode: .source
        )

        XCTAssertEqual(
            segments,
            [
                "Dr. Smith measured 1.5 liters.",
                "Then he left.",
            ]
        )
    }

    func testLiveCaptionSentenceSplitterSplitsCJKWithClosingQuoteAndPendingTail() {
        let segments = LiveCaptionSentenceSplitter.split(
            "他说「这个很重要。」然后大家都点头！最后一句还没结束",
            mode: .translation
        )

        XCTAssertEqual(
            segments,
            [
                "他说「这个很重要。」",
                "然后大家都点头！",
                "最后一句还没结束",
            ]
        )
    }

    func testLiveCaptionSentenceSplitterSoftSplitsLongEnglishWithoutSentencePunctuation() {
        let segments = LiveCaptionSentenceSplitter.split(
            "This realtime stream keeps talking about product strategy, implementation details, and the tradeoffs between latency and readability while the model has not produced sentence punctuation yet",
            mode: .source
        )

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertLessThanOrEqual(segments.map(\.count).max() ?? 0, 90)
        XCTAssertEqual(
            segments.joined(separator: " "),
            "This realtime stream keeps talking about product strategy, implementation details, and the tradeoffs between latency and readability while the model has not produced sentence punctuation yet"
        )
    }

    func testLiveCaptionSentenceSplitterMergesTinyEnglishTailIntoPreviousSegment() {
        let segments = LiveCaptionSentenceSplitter.split(
            "The first thought is already complete. ok",
            mode: .source
        )

        XCTAssertEqual(
            segments,
            ["The first thought is already complete. ok"]
        )
    }

    func testLiveCaptionSentenceSplitterSoftSplitsLongCJKWithoutSentencePunctuation() {
        let text = "这段实时翻译一直在继续输出内容，但是模型暂时没有给出句号，所以界面需要按照逗号和长度做自然分段，避免右侧翻译栏变成一整块难读的文字"
        let segments = LiveCaptionSentenceSplitter.split(text, mode: .translation)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertLessThanOrEqual(segments.map(\.count).max() ?? 0, 42)
        XCTAssertEqual(segments.joined(), text)
    }

    func testLiveCaptionSentenceSplitterMergesTinyCJKTailIntoPreviousSegment() {
        let segments = LiveCaptionSentenceSplitter.split(
            "这个实时翻译段落已经结束。好",
            mode: .translation
        )

        XCTAssertEqual(
            segments,
            ["这个实时翻译段落已经结束。好"]
        )
    }

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

    func testNetworkErrorPresenterLocalizesCommonNetworkFailures() {
        XCTAssertEqual(
            NetworkErrorPresenter.userFacingMessage(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)),
            "网络不可用，请检查连接后重试"
        )
        XCTAssertEqual(
            NetworkErrorPresenter.userFacingMessage(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)),
            "连接超时，请稍后重试"
        )
        XCTAssertEqual(
            NetworkErrorPresenter.userFacingMessage(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)),
            "无法连接 Recappi Cloud，请稍后重试"
        )
        XCTAssertEqual(
            NetworkErrorPresenter.userFacingMessage(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)),
            "安全连接失败，请检查代理或网络设置"
        )
        XCTAssertEqual(
            NetworkErrorPresenter.userFacingMessage(rawMessage: "Socket is not connected"),
            "网络连接中断，请稍后重试"
        )
        XCTAssertEqual(
            NetworkErrorPresenter.userFacingMessage(for: RecappiAPIError.unauthorized),
            "登录已过期，请重新登录"
        )
        XCTAssertEqual(
            NetworkErrorPresenter.userFacingMessage(for: RecappiAPIError.invalidURL),
            "Recappi Cloud 地址无效"
        )
        XCTAssertEqual(
            NetworkErrorPresenter.userFacingMessage(for: RecappiAPIError.invalidResponse),
            "Recappi Cloud 返回了无效响应"
        )
        XCTAssertEqual(
            NetworkErrorPresenter.userFacingMessage(for: RecappiAPIError.http(statusCode: 408, message: "request timeout")),
            "请求超时，请稍后重试"
        )
        XCTAssertEqual(
            NetworkErrorPresenter.userFacingMessage(for: RecappiAPIError.http(statusCode: 409, message: "Already active")),
            "Already active"
        )
        XCTAssertEqual(
            NetworkErrorPresenter.userFacingMessage(for: RecappiAPIError.http(statusCode: 429, message: "rate limit")),
            "请求太频繁，请稍后重试"
        )
        XCTAssertEqual(
            NetworkErrorPresenter.userFacingMessage(for: RecappiAPIError.http(statusCode: 503, message: "upstream down")),
            "Recappi Cloud 暂时不可用，请稍后重试"
        )
        XCTAssertEqual(
            NetworkErrorPresenter.userFacingMessage(
                for: RecappiAPIError.http(
                    statusCode: 503,
                    message: "Subscription is renewing — plan state is between periods. Retry in a few seconds."
                )
            ),
            "订阅状态正在刷新，请几秒后重试"
        )
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

    func testCreateRecordingRetriesSubscriptionRenewal503() async throws {
        StubConnectorURLProtocol.clearStubs()
        defer { StubConnectorURLProtocol.clearStubs() }

        let url = URL(string: "https://recordmeet.ing/api/recordings")!
        let callCounter = StubCallCounter()
        StubConnectorURLProtocol.stub(url: url) { _ in
            let currentCall = callCounter.increment()

            if currentCall == 1 {
                return (
                    Data(#"{"message":"Subscription is renewing — plan state is between periods. Retry in a few seconds."}"#.utf8),
                    503
                )
            }

            return (
                Data(#"{"id":"rec_123","partSize":5242880,"maxPartBytes":99614720,"r2Key":"users/u/rec_123.m4a"}"#.utf8),
                200
            )
        }

        let client = Self.makeStubbedAPIClient(subscriptionRenewalRetryDelays: [.milliseconds(1)])
        let response = try await client.createRecording(
            title: "Renewal retry test",
            contentType: "audio/aac",
            durationMs: 5_000
        )

        XCTAssertEqual(response.id, "rec_123")
        XCTAssertEqual(callCounter.value, 2)
    }

    func testCreateRecordingDoesNotRetryGeneric503Post() async {
        StubConnectorURLProtocol.clearStubs()
        defer { StubConnectorURLProtocol.clearStubs() }

        let url = URL(string: "https://recordmeet.ing/api/recordings")!
        let callCounter = StubCallCounter()
        StubConnectorURLProtocol.stub(url: url) { _ in
            _ = callCounter.increment()
            return (Data(#"{"message":"upstream unavailable"}"#.utf8), 503)
        }

        let client = Self.makeStubbedAPIClient(subscriptionRenewalRetryDelays: [.milliseconds(1)])

        do {
            _ = try await client.createRecording(
                title: "Generic 503 test",
                contentType: "audio/aac",
                durationMs: 5_000
            )
            XCTFail("Expected generic POST 503 to fail without retry.")
        } catch {
            // Expected.
        }

        XCTAssertEqual(callCounter.value, 1)
    }

    func testStartTranscriptionRetriesSubscriptionRenewal503() async throws {
        StubConnectorURLProtocol.clearStubs()
        defer { StubConnectorURLProtocol.clearStubs() }

        let url = URL(string: "https://recordmeet.ing/api/recordings/rec_123/transcribe")!
        let callCounter = StubCallCounter()
        StubConnectorURLProtocol.stub(url: url) { _ in
            let currentCall = callCounter.increment()

            if currentCall == 1 {
                return (
                    Data(#"{"message":"Subscription is renewing — quota window is between periods. Retry in a few seconds."}"#.utf8),
                    503
                )
            }

            return (
                Data(#"{"jobId":"job_123","status":"queued","transcriptId":null}"#.utf8),
                200
            )
        }

        let client = Self.makeStubbedAPIClient(subscriptionRenewalRetryDelays: [.milliseconds(1)])
        let response = try await client.startTranscription(
            recordingId: "rec_123",
            language: "en"
        )

        XCTAssertEqual(response.jobId, "job_123")
        XCTAssertEqual(callCounter.value, 2)
    }

    func testCloudDetailSectionDefaultsToSummaryBeforeSummaryContentLoads() {
        XCTAssertEqual(
            CloudDetailSection.resolveVisibleSection(
                current: .summary,
                hasSummarySection: false,
                transcriptOffset: 0
            ),
            .summary
        )
    }

    func testCloudDetailSectionKeepsManualTranscriptSelectionWithoutSummaryContent() {
        XCTAssertEqual(
            CloudDetailSection.resolveVisibleSection(
                current: .transcript,
                hasSummarySection: false,
                transcriptOffset: 0
            ),
            .transcript
        )
    }

    func testCloudDetailSectionTracksTranscriptOffsetAfterSummaryContentLoads() {
        XCTAssertEqual(
            CloudDetailSection.resolveVisibleSection(
                current: .summary,
                hasSummarySection: true,
                transcriptOffset: 40
            ),
            .transcript
        )
        XCTAssertEqual(
            CloudDetailSection.resolveVisibleSection(
                current: .transcript,
                hasSummarySection: true,
                transcriptOffset: 120
            ),
            .summary
        )
    }

    func testCreateRecordingRequestIncludesNonWavUploadMetadata() throws {
        let body = try JSONEncoder().encode(
            CreateRecordingRequest(
                title: "Daily standup",
                contentType: "audio/mp3",
                durationMs: 125_000
            )
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["title"] as? String, "Daily standup")
        XCTAssertEqual(json["contentType"] as? String, "audio/mp3")
        XCTAssertEqual(json["durationMs"] as? Int, 125_000)
    }

    func testSessionProcessorMapsCloudUploadContentTypes() {
        XCTAssertEqual(
            SessionProcessor.cloudUploadContentType(for: URL(fileURLWithPath: "/tmp/recording.m4a")),
            "audio/aac"
        )
        XCTAssertEqual(
            SessionProcessor.cloudUploadContentType(for: URL(fileURLWithPath: "/tmp/recording.mp3")),
            "audio/mp3"
        )
        XCTAssertEqual(
            SessionProcessor.cloudUploadContentType(for: URL(fileURLWithPath: "/tmp/recording.flac")),
            "audio/flac"
        )
        XCTAssertNil(SessionProcessor.cloudUploadContentType(for: URL(fileURLWithPath: "/tmp/recording.caf")))
    }

    func testSessionProcessorRejectsMissingPrimaryRecordingBeforeUpload() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let missingRecording = RecordingStore.audioFileURL(in: temp)

        do {
            try SessionProcessor.validatePrimaryRecordingForUpload(missingRecording)
            XCTFail("Expected missing recording.m4a to fail before upload.")
        } catch SessionProcessorError.recordingAudioMissing {
            // Expected: don't create a remote recording and then fail upload.
        } catch {
            XCTFail("Expected recordingAudioMissing, got \(error).")
        }
    }

    func testSessionProcessorRejectsEmptyPrimaryRecordingBeforeUpload() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let emptyRecording = RecordingStore.audioFileURL(in: temp)
        try Data().write(to: emptyRecording)

        do {
            try SessionProcessor.validatePrimaryRecordingForUpload(emptyRecording)
            XCTFail("Expected empty recording.m4a to fail before upload.")
        } catch SessionProcessorError.recordingAudioMissing {
            // Expected: a zero-byte capture is not a valid upload asset.
        } catch {
            XCTFail("Expected recordingAudioMissing, got \(error).")
        }
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

    func testFailedRecordingPlaceholderJobCanShowUserFacingError() {
        let job = TranscriptionJob.failedRecordingPlaceholder(
            recordingID: "local-2026-05-25_100318",
            error: "订阅状态正在刷新，请几秒后重试。"
        )

        XCTAssertEqual(job.status, .failed)
        XCTAssertTrue(job.isFailedRecordingPlaceholder)
        XCTAssertEqual(job.error, "订阅状态正在刷新，请几秒后重试。")
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
                prompt: "Run a fresh transcription pass with the default Recappi instructions."
            )
        )
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]

        XCTAssertEqual(json?["provider"] as? String, "gemini")
        XCTAssertEqual(json?["language"] as? String, "en")
        XCTAssertEqual(json?["force"] as? Bool, true)
        XCTAssertNil(json?["summarize"])
        XCTAssertEqual(
            json?["prompt"] as? String,
            "Run a fresh transcription pass with the default Recappi instructions."
        )
    }

    func testRecordingContextPromptCombinesSceneAndExtraPrompt() throws {
        let prompt = try XCTUnwrap(RecordingContextPrompt.text(
            sceneRaw: RecordingSceneTemplate.meeting.rawValue,
            extraPrompt: "Names: Peng, Alice. Product: Recappi Mini."
        ))

        XCTAssertTrue(prompt.contains("Scene: Meeting."))
        XCTAssertTrue(prompt.contains("action items"))
        XCTAssertTrue(prompt.contains("Names: Peng, Alice. Product: Recappi Mini."))
    }

    func testRecordingContextPromptIncludesSceneSpecificSummaryHints() throws {
        let cases: [(RecordingSceneTemplate, String)] = [
            (.meeting, "decisions, action items, and open questions"),
            (.podcast, "episode summary, key topics, notable moments, and follow-up ideas"),
            (.interview, "profile, topic evidence, concerns, and follow-up questions"),
            (.casual, "highlights and things worth remembering"),
            (.lecture, "key concepts, examples, and review points")
        ]

        for (scene, expectedHint) in cases {
            let prompt = try XCTUnwrap(RecordingContextPrompt.text(
                sceneRaw: scene.rawValue,
                extraPrompt: ""
            ))

            XCTAssertTrue(prompt.contains("Scene: \(scene.title)."))
            XCTAssertTrue(prompt.contains(expectedHint))
        }
    }

    func testRecordingContextPromptOmitsBlankExtraPrompt() throws {
        for blank in ["", "   ", "\n\t  "] {
            let prompt = try XCTUnwrap(RecordingContextPrompt.text(
                sceneRaw: RecordingSceneTemplate.meeting.rawValue,
                extraPrompt: blank
            ))

            XCTAssertFalse(prompt.contains("Additional context:"))
        }
    }

    func testRecordingContextPromptTrimsExtraPrompt() throws {
        let prompt = try XCTUnwrap(RecordingContextPrompt.text(
            sceneRaw: RecordingSceneTemplate.meeting.rawValue,
            extraPrompt: "  \n Use CRM names exactly. \t "
        ))

        XCTAssertTrue(prompt.contains("Additional context: Use CRM names exactly."))
        XCTAssertFalse(prompt.contains("Additional context:   "))
        XCTAssertFalse(prompt.contains("exactly. \t"))
    }

    func testRecordingContextPromptBuildsLiveCaptionHint() throws {
        let hint = try XCTUnwrap(RecordingContextPrompt.liveCaptionHint(
            sceneRaw: RecordingSceneTemplate.podcast.rawValue,
            extraPrompt: "  Names: Peng Xiao. Product: Recappi Mini. \n"
        ))

        XCTAssertTrue(hint.contains("Context: This is a podcast recording."))
        XCTAssertTrue(hint.contains("best-effort hint"))
        XCTAssertTrue(hint.contains("Terms and notes: Names: Peng Xiao. Product: Recappi Mini."))
        XCTAssertFalse(hint.contains("summary structure"))
    }

    func testRecordingContextPromptLiveCaptionHintOmitsBlankExtraPrompt() throws {
        let hint = try XCTUnwrap(RecordingContextPrompt.liveCaptionHint(
            sceneRaw: RecordingSceneTemplate.meeting.rawValue,
            extraPrompt: "\n  \t"
        ))

        XCTAssertTrue(hint.contains("Context: This is a meeting recording."))
        XCTAssertFalse(hint.contains("Terms and notes:"))
    }

    func testRecordingContextPromptFallsBackToMeetingWithoutMetadata() throws {
        let prompt = try XCTUnwrap(RecordingContextPrompt.text(from: nil))

        XCTAssertTrue(prompt.contains("Scene: Meeting."))
        XCTAssertTrue(prompt.contains("decisions, action items, and open questions"))
        XCTAssertFalse(prompt.contains("Additional context:"))
    }

    func testRecordingSessionMetadataPersistsRecordingContext() throws {
        let metadata = RecordingSessionMetadata.capture(
            sourceTitle: "Design review",
            sourceAppName: "Zoom",
            sourceBundleID: "us.zoom.xos",
            sceneTemplate: RecordingSceneTemplate.interview.rawValue,
            extraPrompt: "Use product names exactly.",
            includesMicrophoneAudio: false
        )

        XCTAssertEqual(metadata.sceneTemplate, "interview")
        XCTAssertEqual(metadata.extraPrompt, "Use product names exactly.")
        XCTAssertEqual(metadata.includesMicrophoneAudio, false)
    }

    func testRealtimeTranscriptionSessionRequestMatchesBackendContract() throws {
        let body = try JSONEncoder().encode(
            OpenAIRealtimeTranscriptionSessionRequest(
                language: "en-US",
                delay: "low",
                expiresAfterSeconds: 60,
                turnDetection: .none
            )
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let turnDetection = try XCTUnwrap(json["turnDetection"] as? [String: Any])

        XCTAssertEqual(json["mode"] as? String, "transcription")
        XCTAssertEqual(json["language"] as? String, "en-US")
        XCTAssertNil(json["prompt"])
        XCTAssertEqual(json["delay"] as? String, "low")
        XCTAssertEqual(json["expiresAfterSeconds"] as? Int, 60)
        XCTAssertEqual(turnDetection["type"] as? String, "none")
    }

    func testRealtimeTranslationSessionRequestUsesOpenAILanguageCodes() throws {
        let body = try JSONEncoder().encode(
            OpenAIRealtimeTranslationSessionRequest(
                language: "en",
                targetLanguage: "zh",
                delay: "low",
                expiresAfterSeconds: 60,
                includeSourceTranscript: true
            )
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["mode"] as? String, "translation")
        XCTAssertEqual(json["language"] as? String, "en")
        XCTAssertEqual(json["targetLanguage"] as? String, "zh")
        XCTAssertEqual(json["includeSourceTranscript"] as? Bool, true)
    }

    // MARK: - Legacy `BackendRealtimeLiveCaptionTranscriber.handle*ForTesting`
    // -based tests were deleted in Phase 3d alongside the legacy class.
    // Receive-loop transcript / bilingual rendering is now exercised
    // through `RealtimeLiveCaptionActorReceiveTests` and the actor-
    // level translation tests below.

    @MainActor
    func testLiveCaptionCarryoverPreservesHistoryAcrossRestartSnapshots() {
        let carryover = [
            LiveCaptionSegment(
                id: "old-1",
                sourceText: "Existing original line.",
                translatedText: "已有翻译。",
                isFinal: true,
                sequence: 0
            )
        ]
        let incoming = [
            LiveCaptionSegment(
                id: "new-1",
                sourceText: "New original line.",
                translatedText: nil,
                isFinal: false,
                sequence: 1
            )
        ]

        let merged = AudioRecorder.mergedLiveCaptionSegments(carryover: carryover, incoming: incoming)

        XCTAssertEqual(merged.map(\.sourceText), ["Existing original line.", "New original line."])
        XCTAssertEqual(merged.first?.translatedText, "已有翻译。")
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
        XCTAssertNil(transcript.summaryStatus)
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
          "summaryJson": "{\"tldr\":\"Gallery work is ready for review.\",\"keyPoints\":[\"Use a large preview waterfall.\"],\"topics\":[\"Gallery\"],\"decisions\":[\"Keep clone out of scope.\"],\"actionItems\":[{\"what\":\"Review the Gallery waterfall layout.\",\"who\":\"Peng\"},{\"what\":\"  \"}],\"quotes\":[{\"speaker\":\"Peng\",\"text\":\"Make the waterfall feel worth clicking.\"}],\"timeline\":[{\"startMs\":0,\"endMs\":84000,\"title\":\"Kickoff\",\"summary\":\"The team aligned on the Gallery review goals.\"},{\"startMs\":90000,\"endMs\":86000,\"title\":\"Bad\",\"summary\":\"Drop this invalid range.\"}]}"
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
        XCTAssertEqual(transcript.summaryInsights?.timeline.count, 1)
        XCTAssertEqual(transcript.summaryInsights?.timeline.first?.startMs, 0)
        XCTAssertEqual(transcript.summaryInsights?.timeline.first?.endMs, 84_000)
        XCTAssertEqual(transcript.summaryInsights?.timeline.first?.title, "Kickoff")
        XCTAssertEqual(
            transcript.summaryInsights?.timeline.first?.summary,
            "The team aligned on the Gallery review goals."
        )
    }

    func testTranscriptResponseDecodesSummaryStatus() throws {
        let data = """
        {
          "id": "tr_123",
          "text": "Transcript body.",
          "summaryStatus": "running"
        }
        """.data(using: .utf8)!

        let transcript = try JSONDecoder().decode(TranscriptResponse.self, from: data)

        XCTAssertEqual(transcript.summaryStatus, .running)
        XCTAssertTrue(transcript.summaryStatus?.isActive == true)
        XCTAssertNil(transcript.summary)
        XCTAssertNil(transcript.summaryInsights)
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

    func testTranscriptResponsePrefersSegmentsOverPollutedTopLevelText() throws {
        let data = """
        {
          "id": "tr_123",
          "text": "Meeting summary: This is not the verbatim transcript. [Transcript]: teaser",
          "segments": [
            { "startMs": 0, "endMs": 900, "text": "真实逐字稿第一句。" },
            { "startMs": 900, "endMs": 1800, "text": "真实逐字稿第二句。" }
          ]
        }
        """.data(using: .utf8)!

        let transcript = try JSONDecoder().decode(TranscriptResponse.self, from: data)

        XCTAssertEqual(transcript.text, "真实逐字稿第一句。\n真实逐字稿第二句。")
        XCTAssertFalse(transcript.text.contains("Meeting summary"))
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

    func testDoneCloudStatusResolvesFeatureAndManifestStates() {
        XCTAssertEqual(
            DoneCloudStatus.resolve(
                cloudEnabled: false,
                autoTranscribeAfterUpload: true,
                manifest: makeRemoteManifest(stage: "synced"),
                latestJobStatus: nil,
                hasTranscript: false
            ),
            .savedLocally
        )
        XCTAssertEqual(
            DoneCloudStatus.resolve(
                cloudEnabled: true,
                autoTranscribeAfterUpload: true,
                manifest: nil,
                latestJobStatus: nil,
                hasTranscript: false
            ),
            .savedLocally
        )

        XCTAssertEqual(
            DoneCloudStatus.resolve(
                cloudEnabled: true,
                autoTranscribeAfterUpload: true,
                manifest: makeRemoteManifest(stage: "synced"),
                latestJobStatus: nil,
                hasTranscript: false
            ),
            .synced
        )
        XCTAssertEqual(
            DoneCloudStatus.resolve(
                cloudEnabled: true,
                autoTranscribeAfterUpload: false,
                manifest: makeRemoteManifest(stage: "synced"),
                latestJobStatus: nil,
                hasTranscript: false
            ),
            .pending
        )

        XCTAssertEqual(
            DoneCloudStatus.resolve(
                cloudEnabled: true,
                autoTranscribeAfterUpload: true,
                manifest: makeRemoteManifest(stage: "completingUpload"),
                latestJobStatus: nil,
                hasTranscript: false
            ),
            .uploading
        )
        XCTAssertEqual(
            DoneCloudStatus.resolve(
                cloudEnabled: true,
                autoTranscribeAfterUpload: true,
                manifest: makeRemoteManifest(stage: "startingTranscription", jobId: "job_123"),
                latestJobStatus: nil,
                hasTranscript: false
            ),
            .queued
        )
        XCTAssertEqual(
            DoneCloudStatus.resolve(
                cloudEnabled: true,
                autoTranscribeAfterUpload: true,
                manifest: makeRemoteManifest(stage: "fetchingTranscript", jobId: "job_123"),
                latestJobStatus: nil,
                hasTranscript: false
            ),
            .transcribing
        )
    }

    func testDoneCloudStatusPrefersTranscriptAndLatestJob() {
        XCTAssertEqual(
            DoneCloudStatus.resolve(
                cloudEnabled: true,
                autoTranscribeAfterUpload: true,
                manifest: makeRemoteManifest(stage: "synced", transcriptId: "tr_123"),
                latestJobStatus: nil,
                hasTranscript: false
            ),
            .ready
        )
        XCTAssertEqual(
            DoneCloudStatus.resolve(
                cloudEnabled: true,
                autoTranscribeAfterUpload: true,
                manifest: makeRemoteManifest(stage: "synced"),
                latestJobStatus: .running,
                hasTranscript: false
            ),
            .transcribing
        )
        XCTAssertEqual(
            DoneCloudStatus.resolve(
                cloudEnabled: true,
                autoTranscribeAfterUpload: true,
                manifest: makeRemoteManifest(stage: "synced"),
                latestJobStatus: .failed,
                hasTranscript: false
            ),
            .transcriptionFailed
        )
        XCTAssertEqual(
            DoneCloudStatus.resolve(
                cloudEnabled: true,
                autoTranscribeAfterUpload: true,
                manifest: makeRemoteManifest(stage: "synced"),
                latestJobStatus: .succeeded,
                hasTranscript: false
            ),
            .ready
        )
        XCTAssertEqual(
            DoneCloudStatus.resolve(
                cloudEnabled: true,
                autoTranscribeAfterUpload: true,
                manifest: makeRemoteManifest(stage: "uploadFailed"),
                latestJobStatus: nil,
                hasTranscript: false
            ),
            .syncFailed
        )
    }

    func testCloudLibraryDeduplicatesRecordingsByID() {
        let older = CloudRecording(
            id: "rec_duplicate",
            userId: "user_123",
            title: "Meeting at 10:05",
            summaryTitle: nil,
            sourceTitle: nil,
            sourceAppName: nil,
            sourceAppBundleID: nil,
            r2Key: nil,
            r2UploadId: nil,
            status: .uploading,
            sizeBytes: nil,
            durationMs: 42_000,
            sampleRate: nil,
            channels: nil,
            contentType: nil,
            activeTranscriptId: nil,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = CloudRecording(
            id: "rec_duplicate",
            userId: "user_123",
            title: "Meeting at 10:05",
            summaryTitle: "Ready title",
            sourceTitle: nil,
            sourceAppName: nil,
            sourceAppBundleID: nil,
            r2Key: nil,
            r2UploadId: nil,
            status: .ready,
            sizeBytes: nil,
            durationMs: 42_000,
            sampleRate: nil,
            channels: nil,
            contentType: nil,
            activeTranscriptId: "tr_123",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )

        let deduped = CloudLibraryStore.deduplicatedRecordings([newer, older])

        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.id, "rec_duplicate")
        XCTAssertEqual(deduped.first?.status, .ready)
        XCTAssertEqual(deduped.first?.activeTranscriptId, "tr_123")
    }

    @MainActor
    func testCloudLibraryRefreshesCachedLocalOnlyTimestampFromDisk() {
        let store = CloudLibraryStore()
        let staleToday = Date(timeIntervalSince1970: 1_779_954_420)
        let parsedSessionDate = Date(timeIntervalSince1970: 1_777_532_623)
        let cached = CloudRecording(
            id: "local-2026-04-22_153432",
            userId: nil,
            title: "2026-04-22_153432",
            summaryTitle: nil,
            sourceTitle: nil,
            sourceAppName: nil,
            sourceAppBundleID: nil,
            r2Key: nil,
            r2UploadId: nil,
            status: .failed,
            sizeBytes: 128,
            durationMs: nil,
            sampleRate: nil,
            channels: nil,
            contentType: "audio/aac",
            activeTranscriptId: nil,
            createdAt: staleToday,
            updatedAt: staleToday
        )
        let fromDisk = CloudRecording(
            id: cached.id,
            userId: nil,
            title: cached.title,
            summaryTitle: nil,
            sourceTitle: nil,
            sourceAppName: nil,
            sourceAppBundleID: nil,
            r2Key: nil,
            r2UploadId: nil,
            status: .failed,
            sizeBytes: 128,
            durationMs: nil,
            sampleRate: nil,
            channels: nil,
            contentType: "audio/aac",
            activeTranscriptId: nil,
            createdAt: parsedSessionDate,
            updatedAt: parsedSessionDate
        )
        store.recordings = [cached]

        let merged = store.mergeWithLocalOnlyRecordings([], localOnlyRecordings: [fromDisk])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, cached.id)
        XCTAssertEqual(merged.first?.createdAt, parsedSessionDate)
        XCTAssertEqual(merged.first?.updatedAt, parsedSessionDate)
    }

    @MainActor
    func testCloudLibraryAudioFileExtensionMapsAACToPlayableContainer() {
        let store = CloudLibraryStore()
        let recording = CloudRecording(
            id: "rec_aac",
            userId: "user_123",
            title: "Remote AAC",
            summaryTitle: nil,
            sourceTitle: nil,
            sourceAppName: nil,
            sourceAppBundleID: nil,
            r2Key: "recordings/user_123/rec_aac.aac",
            r2UploadId: nil,
            status: .ready,
            sizeBytes: 1024,
            durationMs: 12_000,
            sampleRate: 48_000,
            channels: 2,
            contentType: "audio/aac",
            activeTranscriptId: nil,
            createdAt: nil,
            updatedAt: nil
        )

        XCTAssertEqual(store.audioFileExtension(for: recording), "m4a")
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
        XCTAssertNotNil(store.locallyManagedRecordingUpdatedAt["rec_processing"])
        XCTAssertEqual(store.transcriptionJobsByRecordingID["rec_processing"]?.first?.status, .running)
    }

    @MainActor
    func testCloudLibraryReplacesLocalProcessingRecordingWithServerDetail() {
        let store = CloudLibraryStore()
        let localPlaceholder = CloudRecording(
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
        let serverDetail = CloudRecording(
            id: "rec_processing",
            userId: "user_123",
            title: "Live meeting",
            summaryTitle: "Design sync recap",
            sourceTitle: "Design sync",
            sourceAppName: "Google Meet",
            sourceAppBundleID: "com.google.Chrome",
            r2Key: "recordings/user/rec_processing.wav",
            r2UploadId: nil,
            status: .ready,
            sizeBytes: 4_200_000,
            durationMs: 120_000,
            sampleRate: 48_000,
            channels: 2,
            contentType: "audio/aac",
            activeTranscriptId: "tr_final",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let finishedJob = TranscriptionJob(
            id: "job_processing",
            status: .succeeded,
            transcriptId: "tr_final",
            provider: "Recappi Cloud",
            model: "Transcription",
            language: nil,
            prompt: nil,
            error: nil,
            attempts: 1,
            enqueuedAt: 1_000,
            startedAt: 1_001,
            finishedAt: 2_000
        )

        store.upsertLocalProcessingRecording(localPlaceholder)
        store.upsertLocalProcessingRecording(serverDetail, latestJob: finishedJob)

        let recording = store.recordings.first
        XCTAssertEqual(recording?.id, "rec_processing")
        XCTAssertEqual(recording?.status, .ready)
        XCTAssertEqual(recording?.activeTranscriptId, "tr_final")
        XCTAssertEqual(recording?.updatedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertNotNil(store.locallyManagedRecordingUpdatedAt["rec_processing"])
        XCTAssertEqual(store.transcriptionJobsByRecordingID["rec_processing"]?.first?.status, .succeeded)
    }

    @MainActor
    func testCloudLibraryReplacesLocalOnlyProcessingRowWithRemoteID() {
        let store = CloudLibraryStore()
        let sessionURL = URL(fileURLWithPath: "/tmp/recappi-local-session", isDirectory: true)
        let local = CloudRecording(
            id: "local-2026-05-25_100318",
            userId: nil,
            title: "Arc",
            summaryTitle: nil,
            sourceTitle: "Arc",
            sourceAppName: "Arc",
            sourceAppBundleID: "company.thebrowser.Browser",
            r2Key: nil,
            r2UploadId: nil,
            status: .uploading,
            sizeBytes: 49_741_990,
            durationMs: 60_000,
            sampleRate: nil,
            channels: nil,
            contentType: "audio/aac",
            activeTranscriptId: nil,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let remote = CloudRecording(
            id: "rec_remote",
            userId: nil,
            title: "Arc",
            summaryTitle: nil,
            sourceTitle: "Arc",
            sourceAppName: "Arc",
            sourceAppBundleID: "company.thebrowser.Browser",
            r2Key: "recordings/user/rec_remote.m4a",
            r2UploadId: nil,
            status: .uploading,
            sizeBytes: nil,
            durationMs: 60_000,
            sampleRate: nil,
            channels: nil,
            contentType: "audio/aac",
            activeTranscriptId: nil,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_001)
        )

        store.upsertLocalProcessingRecording(local)
        store.select(local)
        store.localSessionURLsByRecordingID[local.id] = sessionURL
        store.setProcessingPhase(.uploading(progress: 0.42), for: local.id)
        store.upsertLocalProcessingRecording(remote, replacing: local.id)

        XCTAssertEqual(store.recordings.map(\.id), ["rec_remote"])
        XCTAssertEqual(store.selectedRecordingID, "rec_remote")
        XCTAssertNil(store.processingPhasesByRecordingID[local.id])
        XCTAssertEqual(store.processingPhasesByRecordingID["rec_remote"], .uploading(progress: 0.42))
        XCTAssertEqual(store.localSessionURLsByRecordingID["rec_remote"], sessionURL)
    }

    @MainActor
    func testCloudLibraryCanFocusRecordingByIDAfterDoneAction() {
        let store = CloudLibraryStore()
        let previous = CloudRecording.previewSample(id: "rec_previous", title: "Previous meeting")
        let finished = CloudRecording.previewSample(id: "rec_finished", title: "Finished meeting")

        store.upsertLocalProcessingRecording(previous)
        store.select(previous)
        store.upsertLocalProcessingRecording(finished)

        XCTAssertEqual(store.selectedRecordingID, "rec_previous")
        XCTAssertTrue(store.selectRecording(id: "rec_finished"))
        XCTAssertEqual(store.selectedRecordingID, "rec_finished")
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
            transcriptionJobsByRecordingID: ["rec_123": [job]],
            speakerOverridesByRecordingID: [
                "rec_123": [
                    CloudSpeakerModel.speakerID(forRawName: "Peng"): CloudSpeakerDisplayOverride(
                        displayName: "Peng Xiao",
                        emoji: "🎤",
                        note: "Host"
                    ),
                ],
            ]
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
        XCTAssertEqual(
            decoded.decodedSpeakerOverridesByRecordingID["rec_123"]?[CloudSpeakerModel.speakerID(forRawName: "Peng")]?.displayName,
            "Peng Xiao"
        )
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

    func testCloudLibraryCachePersistsSpeakerOverridesInSQLite() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let recording = try JSONDecoder().decode(
            CloudRecording.self,
            from: """
            {
              "id": "rec_speakers",
              "userId": "user_123",
              "title": "Speaker sync",
              "status": "ready"
            }
            """.data(using: .utf8)!
        )
        let speakerID = CloudSpeakerModel.speakerID(forRawName: "Speaker 1")
        let cache = CloudLibraryCache(directoryURL: temp)
        let snapshot = CloudLibrarySnapshot(
            userId: "user_123",
            backendOrigin: "https://recordmeet.ing",
            savedAt: Date(timeIntervalSince1970: 1_776_957_994),
            recordings: [recording],
            nextCursor: nil,
            selectedRecordingID: "rec_speakers",
            billingStatus: nil,
            transcriptCache: [:],
            speakerOverridesByRecordingID: [
                "rec_speakers": [
                    speakerID: CloudSpeakerDisplayOverride(
                        displayName: "Ava",
                        emoji: "🎧",
                        note: "Interviewer"
                    ),
                ],
            ]
        )

        await cache.saveSnapshot(snapshot)

        let loadedSnapshot = await cache.loadSnapshot(userId: "user_123", backendOrigin: "https://recordmeet.ing")
        let loaded = try XCTUnwrap(loadedSnapshot)
        XCTAssertEqual(loaded.decodedSpeakerOverridesByRecordingID["rec_speakers"]?[speakerID]?.displayName, "Ava")
        XCTAssertEqual(loaded.decodedSpeakerOverridesByRecordingID["rec_speakers"]?[speakerID]?.emoji, "🎧")
        XCTAssertEqual(loaded.decodedSpeakerOverridesByRecordingID["rec_speakers"]?[speakerID]?.note, "Interviewer")
    }

    func testCloudLibraryCacheBuildsFTSIndexForTranscriptAndSummary() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let recording = try JSONDecoder().decode(
            CloudRecording.self,
            from: """
            {
              "id": "rec_search",
              "userId": "user_123",
              "title": "Weekly engineering sync",
              "status": "ready"
            }
            """.data(using: .utf8)!
        )
        let transcript = try JSONDecoder().decode(
            TranscriptResponse.self,
            from: """
            {
              "id": "tr_search",
              "text": "Live captions need reconnect states.",
              "summaryJson": "{\\"tldr\\":\\"The team aligned on live caption reconnect polish.\\",\\"keyPoints\\":[\\"Search should include notes and transcripts.\\"]}",
              "segments": [
                { "startMs": 420000, "endMs": 760000, "text": "Live captions need reconnect states.", "speaker": "Chloe" },
                { "startMs": 760000, "endMs": 900000, "text": "Search should cover exact transcript sentences.", "speaker": "Ava" }
              ]
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
            selectedRecordingID: "rec_search",
            billingStatus: nil,
            transcriptCache: ["rec_search": transcript]
        )

        await cache.saveSnapshot(snapshot)

        let captionResults = try await cache.searchCachedRecordings(
            userId: "user_123",
            backendOrigin: "https://recordmeet.ing",
            query: "caption"
        )
        XCTAssertTrue(captionResults.contains { $0.source == .transcript && $0.speakerRawName == "Chloe" })
        XCTAssertTrue(captionResults.contains { $0.source == .summary && $0.sectionBreadcrumb == "Notes · TL;DR" })

        let avaResults = try await cache.searchCachedRecordings(
            userId: "user_123",
            backendOrigin: "https://recordmeet.ing",
            query: "Search",
            speakerRawName: "Ava"
        )
        XCTAssertEqual(avaResults.map(\.speakerRawName), ["Ava"])
        XCTAssertEqual(avaResults.first?.targetSegmentID, "segment-1-760000-900000")
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

    func testNativeOAuthPrefersPersistentBrowserSession() {
        XCTAssertFalse(
            NativeOAuthCoordinator.prefersEphemeralWebBrowserSession,
            "Native OAuth should use the user's normal browser session so Google sign-in does not open a private/incognito browser."
        )
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

    @MainActor
    func testBackendRealtimeLiveCaptionsAreForcedOn() {
        let key = "backendRealtimeLiveCaptionsEnabled"
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.set(true, forKey: key) }

        let config = AppConfig.shared
        XCTAssertTrue(config.backendRealtimeLiveCaptionsEnabled)

        config.backendRealtimeLiveCaptionsEnabled = false
        XCTAssertTrue(config.backendRealtimeLiveCaptionsEnabled)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
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

    func testCloudLibraryIndexesLocalSessionsWithoutRemoteManifestByLocalID() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = temp.appendingPathComponent("2026-05-25_111500", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let links = CloudLibraryStore.localSessionLinks(in: temp)

        XCTAssertEqual(
            links["local-2026-05-25_111500"]?.standardizedFileURL,
            session.standardizedFileURL
        )
    }

    func testLocalFailedRecordingPlaceholderKeepsUploadFailureVisible() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = temp.appendingPathComponent("2026-05-25_111500", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try Data(repeating: 1, count: 128).write(to: RecordingStore.audioFileURL(in: session))
        RecordingStore.saveSessionMetadata(
            .capture(
                sourceTitle: "Design sync",
                sourceAppName: "Google Meet",
                sourceBundleID: "com.google.Chrome",
                includesMicrophoneAudio: true
            ),
            in: session
        )

        let recording = try XCTUnwrap(SessionProcessor.localFailedRecordingPlaceholder(
            sessionDir: session,
            duration: 12,
            error: RecappiAPIError.http(
                statusCode: 503,
                message: "Subscription is renewing — plan state is between periods. Retry in a few seconds."
            )
        ))

        XCTAssertEqual(recording.id, "local-2026-05-25_111500")
        XCTAssertEqual(recording.status, .failed)
        XCTAssertEqual(recording.title, "Design sync")
        XCTAssertEqual(recording.sourceAppName, "Google Meet")
        XCTAssertEqual(recording.durationMs, 12_000)
        XCTAssertEqual(recording.sizeBytes, 128)
        XCTAssertEqual(recording.contentType, "audio/aac")
    }

    func testLocalRecordingPlaceholderIsCreatedImmediatelyAfterStop() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = temp.appendingPathComponent("2026-05-25_112000", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try Data(repeating: 2, count: 256).write(to: RecordingStore.audioFileURL(in: session))

        let recording = try XCTUnwrap(SessionProcessor.localRecordingPlaceholder(
            sessionDir: session,
            duration: 9,
            status: .uploading
        ))

        XCTAssertEqual(recording.id, "local-2026-05-25_112000")
        XCTAssertEqual(recording.status, .uploading)
        XCTAssertEqual(recording.durationMs, 9_000)
        XCTAssertEqual(recording.sizeBytes, 256)
    }

    func testLocalRecordingPlaceholderUsesSessionTimestampWhenMetadataIsMissing() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = temp.appendingPathComponent("2026-04-16_113023", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try Data(repeating: 7, count: 128).write(to: RecordingStore.audioFileURL(in: session))

        let recording = try XCTUnwrap(SessionProcessor.localRecordingPlaceholder(
            sessionDir: session,
            duration: 0,
            status: .uploading
        ))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let expectedDate = try XCTUnwrap(formatter.date(from: "2026-04-16_113023"))

        XCTAssertEqual(recording.title, "2026-04-16_113023")
        let createdAt = try XCTUnwrap(recording.createdAt)
        XCTAssertEqual(createdAt.timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testCloudLibraryFindsLocalOnlyRecordingsFromDisk() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = temp.appendingPathComponent("2026-05-25_112500", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try Data(repeating: 3, count: 64).write(to: RecordingStore.audioFileURL(in: session))
        var manifest = RemoteSessionManifest.stage("uploadFailed")
        manifest.errorMessage = "Subscription is renewing"
        RecordingStore.saveRemoteManifest(manifest, in: session)

        let recordings = CloudLibraryStore.localOnlyRecordings(in: temp)

        XCTAssertEqual(recordings.map(\.id), ["local-2026-05-25_112500"])
        XCTAssertEqual(recordings.first?.status, .failed)
        XCTAssertEqual(recordings.first?.sizeBytes, 64)
    }

    func testSessionProcessorPrimaryAudioFileUsesManifestUploadFilename() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = temp.appendingPathComponent("2026-05-25_112700", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let imported = session.appendingPathComponent("recording.mp3")
        try Data(repeating: 5, count: 96).write(to: imported)
        var manifest = RemoteSessionManifest.stage("imported")
        manifest.uploadFilename = imported.lastPathComponent

        XCTAssertEqual(
            SessionProcessor.primaryAudioFileURL(in: session, manifest: manifest)?.lastPathComponent,
            "recording.mp3"
        )
    }

    func testLocalOnlyRecordingPlaceholderUsesImportedAudioManifestFile() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = temp.appendingPathComponent("2026-05-25_112800", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let imported = session.appendingPathComponent("recording.mp3")
        try Data(repeating: 6, count: 512).write(to: imported)
        var manifest = RemoteSessionManifest.stage("imported")
        manifest.uploadFilename = imported.lastPathComponent
        RecordingStore.saveRemoteManifest(manifest, in: session)

        let recording = try XCTUnwrap(SessionProcessor.localRecordingPlaceholder(
            sessionDir: session,
            duration: 33,
            status: .uploading
        ))

        XCTAssertEqual(recording.id, "local-2026-05-25_112800")
        XCTAssertEqual(recording.sizeBytes, 512)
        XCTAssertEqual(recording.contentType, "audio/mp3")
    }

    func testCloudLibrarySkipsLocalOnlyRecordingAfterRemoteManifestAppears() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = temp.appendingPathComponent("2026-05-25_113000", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try Data(repeating: 4, count: 64).write(to: RecordingStore.audioFileURL(in: session))
        var manifest = RemoteSessionManifest.stage("creatingRecording")
        manifest.recordingId = "rec_remote"
        RecordingStore.saveRemoteManifest(manifest, in: session)

        XCTAssertTrue(CloudLibraryStore.localOnlyRecordings(in: temp).isEmpty)
    }

    @MainActor
    func testCloudLibraryMergesLocalOnlyRecordingsIntoRemoteRefreshResults() {
        let store = CloudLibraryStore()
        let remote = CloudRecording(
            id: "rec_remote",
            userId: "user_123",
            title: "Remote recording",
            summaryTitle: nil,
            sourceTitle: nil,
            sourceAppName: nil,
            sourceAppBundleID: nil,
            r2Key: "recordings/user/rec_remote.m4a",
            r2UploadId: nil,
            status: .ready,
            sizeBytes: 1024,
            durationMs: 30_000,
            sampleRate: nil,
            channels: nil,
            contentType: "audio/aac",
            activeTranscriptId: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let local = CloudRecording(
            id: "local-2026-05-25_113500",
            userId: nil,
            title: "Local only",
            summaryTitle: nil,
            sourceTitle: "All system audio",
            sourceAppName: nil,
            sourceAppBundleID: nil,
            r2Key: nil,
            r2UploadId: nil,
            status: .failed,
            sizeBytes: 2048,
            durationMs: nil,
            sampleRate: nil,
            channels: nil,
            contentType: "audio/aac",
            activeTranscriptId: nil,
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let merged = store.mergeWithLocalOnlyRecordings([remote], localOnlyRecordings: [local])

        XCTAssertEqual(merged.map(\.id), ["local-2026-05-25_113500", "rec_remote"])
        XCTAssertEqual(merged.first?.status, .failed)
    }

    func testLocalOnlyRecordingAllowsProcessingWhenLocalSessionIsLinked() {
        let recording = CloudRecording(
            id: "local-2026-05-25_130800",
            userId: nil,
            title: "Arc",
            summaryTitle: nil,
            sourceTitle: "Arc",
            sourceAppName: "Arc",
            sourceAppBundleID: "company.thebrowser.Browser",
            r2Key: nil,
            r2UploadId: nil,
            status: .failed,
            sizeBytes: 1_024,
            durationMs: 60_000,
            sampleRate: nil,
            channels: nil,
            contentType: "audio/aac",
            activeTranscriptId: nil,
            createdAt: nil,
            updatedAt: nil
        )

        XCTAssertTrue(recording.isLocalOnlyRecording)
        XCTAssertFalse(recording.allowsProcessingRequest(hasLocalSession: false))
        XCTAssertTrue(recording.allowsProcessingRequest(hasLocalSession: true))
    }

    func testRemoteUploadingRecordingStillBlocksProcessing() {
        let recording = CloudRecording(
            id: "rec_uploading",
            userId: "user_123",
            title: "Uploading",
            summaryTitle: nil,
            sourceTitle: nil,
            sourceAppName: nil,
            sourceAppBundleID: nil,
            r2Key: "recordings/user/rec_uploading.m4a",
            r2UploadId: nil,
            status: .uploading,
            sizeBytes: nil,
            durationMs: nil,
            sampleRate: nil,
            channels: nil,
            contentType: "audio/aac",
            activeTranscriptId: nil,
            createdAt: nil,
            updatedAt: nil
        )

        XCTAssertFalse(recording.isLocalOnlyRecording)
        XCTAssertFalse(recording.allowsProcessingRequest(hasLocalSession: true))
    }

    @MainActor
    func testSelectingLocalOnlyRecordingDoesNotLeaveTranscriptLoadingStuck() async {
        let store = CloudLibraryStore()
        let recording = CloudRecording(
            id: "local-2026-05-25_130800",
            userId: nil,
            title: "Arc",
            summaryTitle: nil,
            sourceTitle: "Arc",
            sourceAppName: "Arc",
            sourceAppBundleID: "company.thebrowser.Browser",
            r2Key: nil,
            r2UploadId: nil,
            status: .failed,
            sizeBytes: 1_024,
            durationMs: 60_000,
            sampleRate: nil,
            channels: nil,
            contentType: "audio/aac",
            activeTranscriptId: nil,
            createdAt: nil,
            updatedAt: nil
        )
        store.recordings = [recording]

        store.select(recording)
        await store.loadTranscriptForSelection()

        XCTAssertEqual(store.selectedRecordingID, recording.id)
        XCTAssertFalse(store.isSelectedTranscriptLoading)
    }

    @MainActor
    func testDeletingLocalOnlyRecordingRemovesItWithoutRemoteAuth() async {
        let store = CloudLibraryStore()
        let local = CloudRecording(
            id: "local-2026-05-10_175443",
            userId: nil,
            title: "Local only",
            summaryTitle: nil,
            sourceTitle: "All system audio",
            sourceAppName: nil,
            sourceAppBundleID: nil,
            r2Key: nil,
            r2UploadId: nil,
            status: .failed,
            sizeBytes: 1_024,
            durationMs: 60_000,
            sampleRate: nil,
            channels: nil,
            contentType: "audio/aac",
            activeTranscriptId: nil,
            createdAt: nil,
            updatedAt: nil
        )
        let remote = CloudRecording(
            id: "rec_remote",
            userId: "user_123",
            title: "Remote",
            summaryTitle: nil,
            sourceTitle: nil,
            sourceAppName: nil,
            sourceAppBundleID: nil,
            r2Key: "recordings/user/rec_remote.m4a",
            r2UploadId: nil,
            status: .ready,
            sizeBytes: 2_048,
            durationMs: 120_000,
            sampleRate: nil,
            channels: nil,
            contentType: "audio/aac",
            activeTranscriptId: nil,
            createdAt: nil,
            updatedAt: nil
        )
        store.recordings = [local, remote]
        store.selectedRecordingID = local.id
        store.state = .loaded

        await store.deleteSelectedRecording()

        XCTAssertEqual(store.recordings.map(\.id), [remote.id])
        XCTAssertEqual(store.selectedRecordingID, remote.id)
        XCTAssertEqual(store.state, .loaded)
        XCTAssertFalse(store.isDeleting)
        XCTAssertNil(store.cacheWarningMessage)
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

    func testFloatingPanelConstrainsVisiblePillInsteadOfShadowMargin() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let panelSize = NSSize(
            width: DT.panelWidth + PillShellView.shadowMargin * 2,
            height: 180
        )
        let proposed = NSRect(
            x: 520,
            y: 700,
            width: panelSize.width,
            height: panelSize.height
        )

        let constrained = PillShellView.constrainWindowFrame(proposed, visiblePillTo: screenFrame)
        let visiblePill = PillShellView.visiblePillRect(
            in: NSRect(origin: .zero, size: constrained.size)
        ).offsetBy(dx: constrained.minX, dy: constrained.minY)

        XCTAssertEqual(visiblePill.maxY, screenFrame.maxY)
        XCTAssertLessThan(constrained.maxY, screenFrame.maxY + PillShellView.topShadowMargin + 0.5)
        XCTAssertGreaterThan(constrained.maxY, screenFrame.maxY)
    }

    func testFloatingPanelAllowsContinuousDragInsideShadowMargin() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let panelSize = NSSize(
            width: DT.panelWidth + PillShellView.shadowMargin * 2,
            height: 180
        )
        let startFrame = NSRect(
            x: 520,
            y: 540,
            width: panelSize.width,
            height: panelSize.height
        )
        let startVisiblePill = PillShellView.visiblePillRect(
            in: NSRect(origin: .zero, size: startFrame.size)
        ).offsetBy(dx: startFrame.minX, dy: startFrame.minY)
        let desiredTopGap: CGFloat = 12
        let dragDeltaY = screenFrame.maxY - desiredTopGap - startVisiblePill.maxY

        let constrained = PillShellView.dragWindowFrame(
            startFrame: startFrame,
            startMouse: NSPoint(x: 700, y: 700),
            currentMouse: NSPoint(x: 700, y: 700 + dragDeltaY),
            visiblePillTo: screenFrame
        )
        let visiblePill = PillShellView.visiblePillRect(
            in: NSRect(origin: .zero, size: constrained.size)
        ).offsetBy(dx: constrained.minX, dy: constrained.minY)

        XCTAssertEqual(visiblePill.maxY, screenFrame.maxY - desiredTopGap)
        XCTAssertGreaterThan(constrained.maxY, screenFrame.maxY)
    }

    func testFloatingPanelSkipsPassthroughRefreshDuringDragEvents() {
        XCTAssertFalse(FloatingPanel.shouldRefreshMousePassthrough(for: .leftMouseDragged))
        XCTAssertFalse(FloatingPanel.shouldRefreshMousePassthrough(for: .rightMouseDragged))
        XCTAssertFalse(FloatingPanel.shouldRefreshMousePassthrough(for: .otherMouseDragged))

        XCTAssertTrue(FloatingPanel.shouldRefreshMousePassthrough(for: .mouseMoved))
        XCTAssertTrue(FloatingPanel.shouldRefreshMousePassthrough(for: .leftMouseDown))
        XCTAssertTrue(FloatingPanel.shouldRefreshMousePassthrough(for: .leftMouseUp))
    }

    @MainActor
    func testFloatingPanelAcceptsMouseMovedEventsForCustomTooltips() {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80))
        XCTAssertTrue(panel.acceptsMouseMovedEvents)
    }

    func testFloatingPanelStartsNativeDragAfterSmallSlop() {
        XCTAssertFalse(FloatingPanel.shouldStartNativeDrag(distance: 2.9, alreadyDragging: false))
        XCTAssertTrue(FloatingPanel.shouldStartNativeDrag(distance: 3.0, alreadyDragging: false))
        XCTAssertTrue(FloatingPanel.shouldStartNativeDrag(distance: 0, alreadyDragging: true))
    }

    func testFloatingPanelHiddenSnapPlanAvoidsDisplayFlushAndRedundantOrderOut() {
        XCTAssertEqual(
            FloatingPanelController.hiddenSnapPlan(isVisible: false, framesNearlyMatch: false),
            FloatingPanelController.HiddenSnapPlan(
                shouldSetFrame: true,
                displayFrame: false,
                shouldOrderOut: false
            )
        )
        XCTAssertEqual(
            FloatingPanelController.hiddenSnapPlan(isVisible: false, framesNearlyMatch: true),
            FloatingPanelController.HiddenSnapPlan(
                shouldSetFrame: false,
                displayFrame: false,
                shouldOrderOut: false
            )
        )
        XCTAssertEqual(
            FloatingPanelController.hiddenSnapPlan(isVisible: true, framesNearlyMatch: true),
            FloatingPanelController.HiddenSnapPlan(
                shouldSetFrame: false,
                displayFrame: false,
                shouldOrderOut: true
            )
        )
    }

    func testLiveCaptionPaneVisibilityFallsBackToAvailableStream() {
        XCTAssertEqual(
            LiveCaptionFloatingPanel.effectivePaneVisibility(
                requested: .both,
                hasCaption: false,
                hasTranslation: true
            ),
            .translationOnly
        )
        XCTAssertEqual(
            LiveCaptionFloatingPanel.effectivePaneVisibility(
                requested: .both,
                hasCaption: true,
                hasTranslation: false
            ),
            .captionOnly
        )
        XCTAssertEqual(
            LiveCaptionFloatingPanel.effectivePaneVisibility(
                requested: .both,
                hasCaption: false,
                hasTranslation: false
            ),
            .both
        )
        XCTAssertEqual(
            LiveCaptionFloatingPanel.effectivePaneVisibility(
                requested: .captionOnly,
                hasCaption: false,
                hasTranslation: false
            ),
            .captionOnly
        )
        XCTAssertEqual(
            LiveCaptionFloatingPanel.effectivePaneVisibility(
                requested: .translationOnly,
                hasCaption: false,
                hasTranslation: false
            ),
            .translationOnly
        )
        XCTAssertEqual(
            LiveCaptionFloatingPanel.effectivePaneVisibility(
                requested: .both,
                hasCaption: true,
                hasTranslation: true
            ),
            .both
        )
    }

    func testLiveCaptionModeSwapKeepsTopRightAnchor() {
        let previousFrame = NSRect(x: 320, y: 180, width: 542, height: 94)
        let targetFrame = AppDelegate.liveCaptionFrameAnchoredToTopRight(
            previousFrame: previousFrame,
            targetFrameSize: NSSize(width: 560, height: 216),
            visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 900)
        )

        XCTAssertEqual(targetFrame.maxX, previousFrame.maxX, accuracy: 0.001)
        XCTAssertEqual(targetFrame.maxY, previousFrame.maxY, accuracy: 0.001)
        XCTAssertEqual(targetFrame.origin.y, previousFrame.maxY - targetFrame.height, accuracy: 0.001)
    }

    func testLiveCaptionModeSwapClampsExpandedFrameIntoVisibleArea() {
        let previousFrame = NSRect(x: 320, y: 12, width: 542, height: 94)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let targetFrame = AppDelegate.liveCaptionFrameAnchoredToTopRight(
            previousFrame: previousFrame,
            targetFrameSize: NSSize(width: 560, height: 216),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(targetFrame.maxX, previousFrame.maxX, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(targetFrame.origin.y, visibleFrame.minY + 8)
        XCTAssertLessThanOrEqual(targetFrame.maxY, visibleFrame.maxY - 8)
    }

    func testLiveCaptionCompactResizeBoundsKeepHeightFixedAndAllowNarrowWidth() {
        XCTAssertEqual(LiveCaptionPanelMode.compact.defaultWindowSize.width, 542)
        XCTAssertEqual(LiveCaptionPanelMode.compact.defaultWindowSize.height, 94)
        XCTAssertEqual(LiveCaptionPanelMode.compact.minimumWindowSize.width, 300)
        XCTAssertEqual(LiveCaptionPanelMode.compact.minimumWindowSize.height, 94)
        XCTAssertEqual(LiveCaptionPanelMode.compact.maximumWindowSize.width, 900)
        XCTAssertEqual(LiveCaptionPanelMode.compact.maximumWindowSize.height, 94)
    }

    @MainActor
    func testLiveCaptionCompactPanelKeepsHiddenTitlebarOutOfFrameBounds() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: LiveCaptionPanelMode.compact.defaultWindowSize),
            styleMask: AppDelegate.liveCaptionPanelStyleMask,
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentMinSize = LiveCaptionPanelMode.compact.minimumWindowSize
        panel.contentMaxSize = LiveCaptionPanelMode.compact.maximumWindowSize
        panel.minSize = panel.frameRect(
            forContentRect: NSRect(origin: .zero, size: LiveCaptionPanelMode.compact.minimumWindowSize)
        ).size
        panel.maxSize = panel.frameRect(
            forContentRect: NSRect(origin: .zero, size: LiveCaptionPanelMode.compact.maximumWindowSize)
        ).size

        XCTAssertTrue(AppDelegate.liveCaptionPanelStyleMask.contains(.fullSizeContentView))
        XCTAssertEqual(panel.frame.size.width, 542)
        XCTAssertEqual(panel.frame.size.height, 94)
        XCTAssertEqual(panel.minSize.width, 300)
        XCTAssertEqual(panel.minSize.height, 94)
        XCTAssertEqual(panel.maxSize.width, 900)
        XCTAssertEqual(panel.maxSize.height, 94)
    }

    func testLiveCaptionStreamTitlesIncludeRoleAndLanguage() {
        XCTAssertEqual(
            LiveCaptionFloatingPanel.streamTitle(role: "Original", languageShortTitle: "EN"),
            "Original · EN"
        )
        XCTAssertEqual(
            LiveCaptionFloatingPanel.streamTitle(role: "Translation", languageShortTitle: "ZH"),
            "Translation · ZH"
        )
    }

    func testLiveCaptionCompactRowsShowOriginalAndTranslationLabels() {
        let rows = LiveCaptionFloatingPanel.compactCaptionRows(
            showsTranslation: true,
            paneVisibility: .both,
            captionText: "If you have a team, pay attention to the latest source line",
            translationText: "昨天清了一下 staging 的，看起来没什么问题，只有 qboard 还需要继续确认",
            sourceLanguageShortTitle: "EN",
            targetLanguageShortTitle: "ZH"
        )

        XCTAssertEqual(rows.count, 2)
        // Source side shows just "Original" (auto-detected language, no suffix);
        // only the user-chosen translation target carries a language code.
        XCTAssertEqual(rows[0].label, "Original")
        XCTAssertEqual(rows[1].label, "Translation · ZH")
        XCTAssertFalse(rows[0].isPlaceholder)
        XCTAssertFalse(rows[1].isPlaceholder)
        XCTAssertEqual(rows.map(\.lineLimit), [1, 1])
        XCTAssertTrue(rows[0].text.contains("latest source line"))
        XCTAssertTrue(rows[1].text.contains("qboard"))
    }

    func testLiveCaptionCompactRowsAllowTwoLinesForOriginalOnly() {
        let rows = LiveCaptionFloatingPanel.compactCaptionRows(
            showsTranslation: false,
            paneVisibility: .captionOnly,
            captionText: "The compact panel should keep more of the original transcript visible when it is the only selected live caption stream",
            translationText: "",
            sourceLanguageShortTitle: "EN",
            targetLanguageShortTitle: "ZH"
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].label, "Original")
        XCTAssertEqual(rows[0].lineLimit, 2)
        XCTAssertFalse(rows[0].isPlaceholder)
        XCTAssertTrue(rows[0].text.contains("only selected live caption stream"))
    }

    func testLiveCaptionCompactRowsDoNotPretruncateLongText() {
        let text = "First sentence should remain present while later words continue filling the compact live caption viewport without head or tail ellipsis"
        let rows = LiveCaptionFloatingPanel.compactCaptionRows(
            showsTranslation: false,
            paneVisibility: .captionOnly,
            captionText: text,
            translationText: "",
            sourceLanguageShortTitle: "EN",
            targetLanguageShortTitle: "ZH"
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].text, text)
        XCTAssertFalse(rows[0].text.contains("…"))
    }

    func testLiveCaptionCompactRowsAllowTwoLinesForTranslationOnly() {
        let rows = LiveCaptionFloatingPanel.compactCaptionRows(
            showsTranslation: true,
            paneVisibility: .translationOnly,
            captionText: "Hidden original stream",
            translationText: "翻译单独显示的时候也要保留两行空间，避免 compact 模式浪费第二行高度",
            sourceLanguageShortTitle: "EN",
            targetLanguageShortTitle: "ZH"
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].label, "Translation · ZH")
        XCTAssertEqual(rows[0].lineLimit, 2)
        XCTAssertFalse(rows[0].isPlaceholder)
        XCTAssertTrue(rows[0].text.contains("第二行高度"))
    }

    func testLiveCaptionCompactRowsKeepTranslationPlaceholderVisible() {
        let rows = LiveCaptionFloatingPanel.compactCaptionRows(
            showsTranslation: true,
            paneVisibility: .both,
            captionText: "Listening source stream",
            translationText: "",
            sourceLanguageShortTitle: "EN",
            targetLanguageShortTitle: "ZH"
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].label, "Original")
        XCTAssertEqual(rows[0].text, "Listening source stream")
        XCTAssertEqual(rows[1].label, "Translation · ZH")
        XCTAssertEqual(rows[1].text, "Waiting for translation")
        XCTAssertEqual(rows.map(\.lineLimit), [1, 1])
        XCTAssertTrue(rows[1].isPlaceholder)
    }

    func testLiveCaptionPlaceholdersAreStreamSpecific() {
        let rows = LiveCaptionFloatingPanel.compactCaptionRows(
            showsTranslation: true,
            paneVisibility: .both,
            captionText: "",
            translationText: "",
            sourceLanguageShortTitle: "EN",
            targetLanguageShortTitle: "JA"
        )

        XCTAssertEqual(rows.map(\.text), [
            LiveCaptionFloatingPanel.originalPlaceholderText,
            LiveCaptionFloatingPanel.translationPlaceholderText,
        ])
        XCTAssertTrue(rows.allSatisfy(\.isPlaceholder))
    }

    @MainActor
    func testCustomTooltipDoesNotAnimateMaterialWindowRetargets() {
        let duration = RecappiTooltipController.retargetFrameAnimationDuration
        XCTAssertEqual(duration, 0)
    }

    @MainActor
    func testFloatingPanelResizeKeepsTopEdgeAnchored() {
        let frame = NSRect(x: 100, y: 200, width: 320, height: 120)
        let resized = FloatingPanelController.contentResizeFrame(
            from: frame,
            to: NSSize(width: 320, height: 172)
        )

        XCTAssertEqual(resized.maxY, frame.maxY)
        XCTAssertEqual(resized.origin.y, 148)
        XCTAssertEqual(resized.size.width, 320)
        XCTAssertEqual(resized.size.height, 172)
    }

    func testRecordingPanelKeepsPostRecordingStatesAtStableMinHeight() {
        XCTAssertNil(RecordingPanel.contentMinHeight(for: .idle))
        XCTAssertNil(RecordingPanel.contentMinHeight(for: .starting))

        XCTAssertEqual(
            RecordingPanel.contentMinHeight(for: .recording),
            RecordingPanel.activeCaptureContentMinHeight
        )
        XCTAssertEqual(
            RecordingPanel.contentMinHeight(for: .processing(.polling(jobStatus: "summarizing"))),
            RecordingPanel.activeCaptureContentMinHeight
        )
        XCTAssertEqual(
            RecordingPanel.contentMinHeight(for: .done(result: RecordingResult(
                folderURL: FileManager.default.temporaryDirectory,
                transcript: nil,
                duration: 74
            ))),
            nil
        )
        XCTAssertEqual(
            RecordingPanel.contentMinHeight(for: .error(message: "Cloud session expired.")),
            RecordingPanel.activeCaptureContentMinHeight
        )
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

    func testAudioMixerDoesNotSilentlyDropUnreadableMicSource() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let invalidMic = temp.appendingPathComponent("mic.m4a")
        try Data("not an audio file".utf8).write(to: invalidMic)
        let destination = temp.appendingPathComponent("mixed-recording.m4a")

        do {
            try await AudioMixer.mix(
                sources: [AutomationPaths.recordingFixture, invalidMic],
                to: destination
            )
            XCTFail("Expected an unreadable supplied mic source to fail the mix.")
        } catch RecorderError.exportFailed {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        } catch {
            XCTFail("Expected RecorderError.exportFailed, got \(error).")
        }
    }

    func testAudioMixerReportsNoCapturedAudioForEmptySourceList() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let destination = temp.appendingPathComponent("mixed-recording.m4a")

        do {
            try await AudioMixer.mix(sources: [], to: destination)
            XCTFail("Expected an empty capture to fail as noCapturedAudio.")
        } catch RecorderError.noCapturedAudio {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        } catch {
            XCTFail("Expected RecorderError.noCapturedAudio, got \(error).")
        }
    }

    func testAudioCaptureDiagnosticsWritesCaptureHealthAndByteCounts() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let source = temp.appendingPathComponent("system.m4a")
        try Data([1, 2, 3]).write(to: source)
        let health = [
            CaptureAudioHealth(
                source: "system",
                bufferCount: 0,
                includedBufferCount: nil,
                firstBufferUptime: nil,
                lastBufferUptime: nil,
                secondsSinceLastBuffer: nil
            ),
            CaptureAudioHealth(
                source: "mic",
                bufferCount: 12,
                includedBufferCount: 12,
                firstBufferUptime: 100,
                lastBufferUptime: 104,
                secondsSinceLastBuffer: 0.25
            ),
        ]

        AudioCaptureDiagnostics.write(
            sources: [source],
            output: nil,
            to: temp,
            captureHealth: health
        )

        let diagnosticsURL = temp.appendingPathComponent("audio-capture.json")
        let data = try Data(contentsOf: diagnosticsURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let diagnostics = try decoder.decode(AudioCaptureDiagnostics.self, from: data)

        XCTAssertEqual(diagnostics.sources.first?.byteCount, 3)
        XCTAssertEqual(diagnostics.captureHealth, health)
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

    func testSpectrumExtractorHandlesInvalidBucketCountWithoutTrap() {
        let sampleRate = 48_000.0
        let samples = sineWave(
            frequency: 1_000,
            sampleRate: sampleRate,
            duration: 0.04,
            amplitude: 0.7
        )

        XCTAssertEqual(
            AudioLevelExtractor.analyzeSamplesForTesting(samples, sampleRate: sampleRate, bucketCount: 0),
            []
        )
        XCTAssertEqual(
            AudioLevelExtractor.analyzeSamplesForTesting(samples, sampleRate: sampleRate, bucketCount: -4),
            []
        )
    }

    func testSpectrumExtractorHandlesInvalidSampleRateWithoutTrap() {
        let samples = sineWave(
            frequency: 1_000,
            sampleRate: 48_000,
            duration: 0.04,
            amplitude: 0.7
        )

        let zeroRateBands = AudioLevelExtractor.analyzeSamplesForTesting(
            samples,
            sampleRate: 0,
            bucketCount: 8
        )
        let nanRateBands = AudioLevelExtractor.analyzeSamplesForTesting(
            samples,
            sampleRate: .nan,
            bucketCount: 8
        )

        XCTAssertEqual(zeroRateBands.count, 8)
        XCTAssertEqual(nanRateBands.count, 8)
        XCTAssertTrue(zeroRateBands.allSatisfy { $0.isFinite })
        XCTAssertTrue(nanRateBands.allSatisfy { $0.isFinite })
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

    func testDotMatrixUsesSoftBoundaryOpacity() {
        let opacities = DotMatrixWaveformModel.litRowOpacities(for: [0.18], rows: 5).first ?? []

        XCTAssertTrue(opacities.contains { $0 > 0 && $0 < 1 })
        XCTAssertEqual(opacities.last ?? 0, 1, accuracy: 0.001)
    }

    func testDotMatrixLeavesSilenceFullyTransparent() {
        let opacities = DotMatrixWaveformModel.litRowOpacities(for: Array(repeating: 0, count: 4), rows: 5)

        XCTAssertTrue(opacities.flatMap { $0 }.allSatisfy { $0 == 0 })
    }

    func testRecorderStateRequiresQuitConfirmationWhileCapturing() {
        XCTAssertTrue(RecorderState.starting.requiresQuitConfirmation)
        XCTAssertTrue(RecorderState.recording.requiresQuitConfirmation)
        XCTAssertFalse(RecorderState.idle.requiresQuitConfirmation)
        XCTAssertFalse(RecorderState.processing(.savingAudio).requiresQuitConfirmation)
        XCTAssertFalse(RecorderState.done(result: RecordingResult(folderURL: URL(fileURLWithPath: "/tmp/session"), transcript: nil, duration: 1)).requiresQuitConfirmation)
        XCTAssertFalse(RecorderState.error(message: "Failed").requiresQuitConfirmation)
    }

    @MainActor
    func testAppLifecycleDelegateProxyForwardsIdleTermination() {
        let proxy = AppLifecycleDelegateProxy()

        XCTAssertEqual(proxy.applicationShouldTerminate(.shared), .terminateNow)
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
    func testRecordingMeterDoesNotLetSilentSystemFramesStarveMicPeak() {
        let recorder = AudioRecorder()
        let silent = AudioMeterFrame(
            peak: 0,
            bands: Array(repeating: 0, count: AudioRecorder.spectrumBucketCount)
        )
        let mic = AudioMeterFrame(
            peak: 0.9,
            bands: Array(repeating: 0.9, count: AudioRecorder.spectrumBucketCount)
        )

        // Frame 1 opens a publish window; frame 2 accumulates the mic
        // peak between publishes; frame 3 (silent) must cross the next
        // publish boundary so the accumulated peak still surfaces. The
        // third timestamp is spaced past the ~20 Hz publish interval
        // (1/20 = 0.05s); it was 0.04s back when the cadence was 30 Hz.
        recorder.ingestMeterFrameForTesting(silent, now: 1.0)
        recorder.ingestMeterFrameForTesting(mic, now: 1.01)
        recorder.ingestMeterFrameForTesting(silent, now: 1.06)

        XCTAssertGreaterThan(recorder.audioLevel, 0.8)
        XCTAssertGreaterThan(recorder.audioSpectrumLevels.max() ?? 0, 0.8)
    }

    func testAudioMeterFrameGateThrottlesVisualizationWork() {
        var gate = AudioMeterFrameGate(minimumInterval: 0.1)

        XCTAssertTrue(gate.shouldEmit(at: 10.0))
        XCTAssertFalse(gate.shouldEmit(at: 10.03))
        XCTAssertFalse(gate.shouldEmit(at: 10.09))
        XCTAssertTrue(gate.shouldEmit(at: 10.11))
        XCTAssertFalse(gate.shouldEmit(at: 10.16))
        XCTAssertTrue(gate.shouldEmit(at: 10.22))
    }

    @MainActor
    func testDiscardRecordingReturnsIdleWithoutProcessingPhase() async {
        let recorder = AudioRecorder()
        var observedStates: [RecorderState] = []
        let cancellable = recorder.$state.sink { observedStates.append($0) }
        defer { cancellable.cancel() }

        recorder.state = .recording
        recorder.elapsedSeconds = 12

        await recorder.discardRecording()

        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(recorder.elapsedSeconds, 0)
        XCTAssertFalse(
            observedStates.contains { state in
                if case .processing = state {
                    return true
                }
                return false
            },
            "Discarding a recording must not reuse the stop/save path that shows a preparing/processing state."
        )
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
        XCTAssertNotNil(match?.sessionKey)
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

    func testBrowserMeetingDetectorSessionKeyTracksMeetingURLNotJustTitle() {
        let first = BrowserMeetingDetector.classify(
            urlString: "https://meet.google.com/abc-defg-hij?pli=1",
            title: "Daily sync - Google Meet",
            browserName: "Google Chrome"
        )
        let sameWithoutQuery = BrowserMeetingDetector.classify(
            urlString: "https://meet.google.com/abc-defg-hij",
            title: "Different visible title",
            browserName: "Google Chrome"
        )
        let second = BrowserMeetingDetector.classify(
            urlString: "https://meet.google.com/xyz-uvwx-rst",
            title: "Daily sync - Google Meet",
            browserName: "Google Chrome"
        )

        XCTAssertEqual(first?.sessionKey, sameWithoutQuery?.sessionKey)
        XCTAssertNotEqual(first?.sessionKey, second?.sessionKey)
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

    // MARK: - CloudLibraryStore.shouldSuppressNewerVersionBannerForLocalPipeline

    func test_shouldSuppressNewerVersionBannerForLocalPipeline_returnsTrue_withinWindow() {
        let lastLocalUpdate = Date(timeIntervalSinceReferenceDate: 100)
        let now = Date(timeIntervalSinceReferenceDate: 100 + 29 * 60)

        XCTAssertTrue(CloudLibraryStore.shouldSuppressNewerVersionBannerForLocalPipeline(
            lastLocalUpdateAt: lastLocalUpdate,
            now: now
        ))
    }

    func test_shouldSuppressNewerVersionBannerForLocalPipeline_returnsFalse_afterWindow() {
        let lastLocalUpdate = Date(timeIntervalSinceReferenceDate: 100)
        let now = Date(timeIntervalSinceReferenceDate: 100 + 31 * 60)

        XCTAssertFalse(CloudLibraryStore.shouldSuppressNewerVersionBannerForLocalPipeline(
            lastLocalUpdateAt: lastLocalUpdate,
            now: now
        ))
    }

    func test_shouldSuppressNewerVersionBannerForLocalPipeline_returnsFalse_withoutMarker() {
        XCTAssertFalse(CloudLibraryStore.shouldSuppressNewerVersionBannerForLocalPipeline(
            lastLocalUpdateAt: nil,
            now: Date(timeIntervalSinceReferenceDate: 100)
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

    func test_shouldClearNewerVersionFlag_returnsTrue_whenLoadedTranscriptMatchesActive() {
        XCTAssertTrue(CloudLibraryStore.shouldClearNewerVersionFlag(
            activeTranscriptId: "trans_v2",
            loadedTranscriptId: "trans_v2"
        ))
    }

    func test_shouldClearNewerVersionFlag_returnsFalse_whenLoadedTranscriptIsNotActive() {
        XCTAssertFalse(CloudLibraryStore.shouldClearNewerVersionFlag(
            activeTranscriptId: "trans_v2",
            loadedTranscriptId: "trans_v1"
        ))
    }

    func test_hasSummaryContentRecognizesTimelineOnlyInsights() throws {
        let data = """
        {
          "id": "trans-test",
          "text": "hello",
          "segments": [],
          "summaryInsights": {
            "timeline": [
              {
                "startMs": 0,
                "endMs": 12000,
                "title": "Opening",
                "summary": "The meeting starts with context."
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let transcript = try JSONDecoder().decode(TranscriptResponse.self, from: data)

        XCTAssertTrue(CloudLibraryStore.hasSummaryContent(transcript))
    }

    func test_cloudDetailRefreshesReadyMissingSummaryWhenOpeningSummaryOrChapters() throws {
        let transcript = try makeTranscript(summary: nil, hasInsights: false)

        XCTAssertTrue(CloudRecordingDetail.shouldRefreshDetailWhenActivating(
            section: .summary,
            recordingStatus: .ready,
            activeTranscriptId: "trans-test",
            transcript: transcript,
            isViewingHistoricalVersion: false,
            isTranscriptLoading: false
        ))
        XCTAssertTrue(CloudRecordingDetail.shouldRefreshDetailWhenActivating(
            section: .timeline,
            recordingStatus: .ready,
            activeTranscriptId: "trans-test",
            transcript: transcript,
            isViewingHistoricalVersion: false,
            isTranscriptLoading: false
        ))
    }

    func test_cloudDetailDoesNotRefreshWhenSummaryContentIsPresentOrNotSummaryNavigation() throws {
        let transcript = try makeTranscript(summary: "already fresh", hasInsights: false)

        XCTAssertFalse(CloudRecordingDetail.shouldRefreshDetailWhenActivating(
            section: .summary,
            recordingStatus: .ready,
            activeTranscriptId: "trans-test",
            transcript: transcript,
            isViewingHistoricalVersion: false,
            isTranscriptLoading: false
        ))
        XCTAssertFalse(CloudRecordingDetail.shouldRefreshDetailWhenActivating(
            section: .transcript,
            recordingStatus: .ready,
            activeTranscriptId: "trans-test",
            transcript: nil,
            isViewingHistoricalVersion: false,
            isTranscriptLoading: false
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

    private func makeRemoteManifest(
        stage: String,
        recordingId: String? = "rec_123",
        jobId: String? = nil,
        transcriptId: String? = nil
    ) -> RemoteSessionManifest {
        var manifest = RemoteSessionManifest.stage(stage)
        manifest.recordingId = recordingId
        manifest.jobId = jobId
        manifest.transcriptId = transcriptId
        return manifest
    }

    private static func makeStubbedAPIClient(
        subscriptionRenewalRetryDelays: [Duration] = []
    ) -> RecappiAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubConnectorURLProtocol.self]
        return RecappiAPIClient(
            origin: "https://recordmeet.ing",
            bearerToken: "token_123",
            session: URLSession(configuration: config),
            subscriptionRenewalRetryDelays: subscriptionRenewalRetryDelays
        )
    }
}

private final class StubCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
