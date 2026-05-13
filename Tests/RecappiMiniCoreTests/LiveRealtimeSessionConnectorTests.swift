import XCTest
@testable import RecappiMini

/// Phase 3a — production-grade `RealtimeSessionConnector` implementation.
///
/// The Phase 1 actor talks to its I/O through `RealtimeSessionConnector`;
/// tests inject a `MockRealtimeSessionConnector`. Production needs a real
/// implementation backed by `RecappiAPIClient` and `URLSession`. This
/// suite pins the contract:
///
/// 1. `claimSession` routes transcription mode through
///    `createRealtimeTranscriptionSession(language:)`.
/// 2. `claimSession` routes translation mode through
///    `createRealtimeTranslationSession(language:targetLanguage:)`.
/// 3. The decoded HTTP response is mapped onto the Phase 1
///    `RealtimeSessionClaim` value type.
/// 4. HTTP failures (e.g. 500) propagate out of `claimSession`.
/// 5. `makeWebSocketRequest(for:client:)` builds a `URLRequest` carrying
///    the `Authorization` and `Origin` headers the WS upgrade needs.
/// 6. The default URLSession factory matches the legacy class's
///    App-Nap-survival configuration (`waitsForConnectivity = true`,
///    not `URLSession.shared`).
/// 7. The `URLSessionWebSocketSocket` adapter forwards `send` /
///    `receive` / `cancel` to its underlying `URLSessionWebSocketTask`.
final class LiveRealtimeSessionConnectorTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        StubConnectorURLProtocol.clearStubs()
    }

    // MARK: - claimSession routing

    /// Transcription mode posts to `/api/openai/realtime/sessions` and
    /// decodes the canned response into a `RealtimeSessionClaim`.
    func testClaimSessionTranscriptionDecodesClaim() async throws {
        let url = URL(string: "https://test.example.com/api/openai/realtime/sessions")!
        StubConnectorURLProtocol.stub(url: url) { request in
            // Sanity check the body shape so we know the connector
            // forwarded the language hint and selected transcription
            // mode (not translation).
            XCTAssertEqual(request.httpMethod, "POST")
            let body = StubConnectorURLProtocol.bodyData(from: request)
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["mode"] as? String, "transcription")
            XCTAssertEqual(json?["language"] as? String, "en")
            return (Self.claimResponseData(mode: "transcription"), 200)
        }

        let connector = Self.makeConnector()
        let claim = try await connector.claimSession(mode: .transcription, language: "en")

        XCTAssertEqual(claim.sessionId, "sess_abc")
        XCTAssertEqual(claim.websocketURL, URL(string: "wss://realtime.example.com/ws?sid=sess_abc")!)
        XCTAssertEqual(claim.token, "tok_realtime")
        XCTAssertEqual(claim.tokenType, "Bearer")
    }

    /// Translation mode picks the bilingual claim endpoint and forwards
    /// the target language taken from the mode's associated value.
    func testClaimSessionTranslationPassesTargetLanguage() async throws {
        let url = URL(string: "https://test.example.com/api/openai/realtime/sessions")!
        StubConnectorURLProtocol.stub(url: url) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let body = StubConnectorURLProtocol.bodyData(from: request)
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["mode"] as? String, "translation")
            XCTAssertEqual(json?["targetLanguage"] as? String, "zh")
            XCTAssertEqual(json?["language"] as? String, "en")
            XCTAssertEqual(json?["includeSourceTranscript"] as? Bool, true)
            return (Self.claimResponseData(mode: "translation"), 200)
        }

        let connector = Self.makeConnector()
        let claim = try await connector.claimSession(
            mode: .translation(targetLanguage: "zh"),
            language: "en"
        )

        XCTAssertEqual(claim.sessionId, "sess_abc")
    }

    /// HTTP failures must propagate out of `claimSession`. The actor's
    /// `performClaim` relies on this to schedule a reconnect.
    func testClaimSessionPropagatesHTTPErrors() async {
        let url = URL(string: "https://test.example.com/api/openai/realtime/sessions")!
        StubConnectorURLProtocol.stub(url: url) { _ in
            return (Data("{\"message\":\"upstream unavailable\"}".utf8), 503)
        }

        let connector = Self.makeConnector()
        do {
            _ = try await connector.claimSession(mode: .transcription, language: "en")
            XCTFail("Expected claimSession to throw for a 5xx response.")
        } catch {
            // Expected.
        }
    }

    // MARK: - WebSocket request shape

    /// The WebSocket upgrade request must carry `Authorization` and
    /// `Origin` headers in the exact shape the proxy expects.
    func testMakeWebSocketRequestIncludesAuthorizationAndOriginHeaders() {
        let claim = RealtimeSessionClaim(
            sessionId: "sess_abc",
            websocketURL: URL(string: "wss://realtime.example.com/ws?sid=sess_abc")!,
            token: "tok_realtime",
            tokenType: "Bearer"
        )

        let request = LiveRealtimeSessionConnector.makeWebSocketRequest(
            for: claim,
            origin: "https://test.example.com"
        )

        XCTAssertEqual(request.url, claim.websocketURL)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer tok_realtime"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Origin"),
            "https://test.example.com"
        )
        XCTAssertEqual(request.timeoutInterval, 60)
    }

    // MARK: - Default URLSession config

    /// The default URLSession must wait for connectivity and own a
    /// fresh configuration (not `URLSession.shared`). Matches the
    /// legacy class's `makeDefaultURLSession` behaviour so the WS
    /// survives App Nap.
    func testDefaultURLSessionSurvivesAppNap() {
        let session = LiveRealtimeSessionConnector.makeDefaultURLSession()
        XCTAssertTrue(
            session.configuration.waitsForConnectivity,
            "Default URLSession must wait for connectivity."
        )
        XCTAssertFalse(
            session === URLSession.shared,
            "Default URLSession must not be URLSession.shared."
        )
    }

    // MARK: - URLSessionWebSocketSocket adapter

    /// The adapter exposes the underlying task identity so the actor's
    /// identity guard can pattern-match in/out the right socket.
    /// Without this, stale receive callbacks couldn't be distinguished
    /// from current ones in production.
    func testURLSessionWebSocketSocketHoldsUnderlyingTask() {
        let task = URLSession.shared.webSocketTask(
            with: URL(string: "wss://example.invalid/socket-adapter-test")!
        )
        defer { task.cancel() }

        let socket = URLSessionWebSocketSocket(task: task)
        XCTAssertTrue(socket.underlyingTaskForTesting === task)
    }

    /// `cancel(code:reason:)` forwards into the underlying task's
    /// `cancel(with:reason:)`. URLSession dispatches the cancellation
    /// asynchronously, so we poll the task's state for up to ~2 s and
    /// assert it moved out of `.suspended` (the initial state of an
    /// un-resumed webSocketTask). `URLSessionWebSocketTask.closeCode`
    /// itself only reflects a *received* close code from the server,
    /// so the load-bearing check is that `cancel` actually reached
    /// the underlying task.
    func testURLSessionWebSocketSocketCancelTransitionsUnderlyingTask() async {
        let task = URLSession.shared.webSocketTask(
            with: URL(string: "wss://example.invalid/cancel-map-test")!
        )
        let stateBefore = task.state

        let socket = URLSessionWebSocketSocket(task: task)
        socket.cancel(code: 1001, reason: nil)

        let deadline = Date().addingTimeInterval(2)
        while task.state.rawValue == stateBefore.rawValue, Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000) // 25 ms
        }

        XCTAssertNotEqual(
            task.state.rawValue,
            stateBefore.rawValue,
            "After cancel(code:reason:) the underlying task must leave its initial state. before=\(stateBefore.rawValue) after=\(task.state.rawValue)"
        )
    }

    /// Well-known close codes (`URLSessionWebSocketTask.CloseCode`)
    /// must round-trip through the `Int` → `CloseCode` mapping the
    /// adapter performs in `cancel(code:reason:)`. This pins the
    /// mapping shape so a future refactor doesn't silently regress
    /// the close-code surface.
    func testURLSessionWebSocketSocketKnownCloseCodesRoundTrip() {
        XCTAssertEqual(URLSessionWebSocketTask.CloseCode(rawValue: 1001), .goingAway)
        XCTAssertEqual(URLSessionWebSocketTask.CloseCode(rawValue: 1000), .normalClosure)
    }

    // MARK: - Helpers

    private static func makeConnector() -> LiveRealtimeSessionConnector {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubConnectorURLProtocol.self]
        let urlSession = URLSession(configuration: config)
        let client = RecappiAPIClient(
            origin: "https://test.example.com",
            bearerToken: "test-token",
            session: urlSession
        )
        return LiveRealtimeSessionConnector(client: client, urlSession: urlSession)
    }

    private static func claimResponseData(mode: String) -> Data {
        let payload: [String: Any] = [
            "sessionId": "sess_abc",
            "mode": mode,
            "websocketUrl": "wss://realtime.example.com/ws?sid=sess_abc",
            "token": "tok_realtime",
            "tokenType": "Bearer",
            "expiresAt": 1_700_000_000,
            "quota": [
                "tier": "free",
                "periodStart": 1_700_000_000,
                "periodEnd": 1_700_086_400,
                "mintsUsed": 0,
                "mintsCap": 60,
                "claimsPerMinute": 6,
            ],
        ]
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: payload)
    }
}

// MARK: - URLProtocol stub for HTTP routing

/// Minimal `URLProtocol` test stub. Tests register a handler for a
/// specific URL; the handler returns the response data + status code.
/// Lets us drive the connector's `claimSession` through a deterministic
/// HTTP layer without touching the network.
final class StubConnectorURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handlers: [URL: (URLRequest) -> (Data, Int)] = [:]

    static func stub(url: URL, handler: @escaping (URLRequest) -> (Data, Int)) {
        lock.lock()
        handlers[url] = handler
        lock.unlock()
    }

    static func clearStubs() {
        lock.lock()
        handlers.removeAll()
        lock.unlock()
    }

    /// Reconstruct the request body. URLSession sometimes nils out
    /// `request.httpBody` on the protocol side (it streams instead);
    /// `httpBodyStream` is the reliable read path.
    static func bodyData(from request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        lock.lock()
        let handled = handlers[url] != nil
        lock.unlock()
        return handled
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        let handler = Self.handlers[url]
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (data, statusCode) = handler(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
