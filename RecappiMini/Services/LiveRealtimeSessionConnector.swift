import Foundation

/// Phase 3a — production `RealtimeSessionConnector` implementation. The
/// Phase 1 actor (`RealtimeLiveCaptionActor`) is the lifecycle owner
/// for backend live captions; this struct wires it to the real
/// `RecappiAPIClient` HTTP claim path and a real
/// `URLSessionWebSocketTask`. Phase 3d deleted the previous
/// monolithic transcriber and routed `AudioRecorder` through the
/// actor exclusively.
///
/// Design notes:
/// - HTTP claim is delegated to the existing `RecappiAPIClient`
///   helpers (`createRealtimeTranscriptionSession(language:)` /
///   `createRealtimeTranslationSession(language:targetLanguage:)`).
///   This keeps the request shape, retry semantics, and error mapping
///   identical to the legacy class so the swap is purely structural.
/// - `URLSession` is owned here, not shared, so the App-Nap-survival
///   tuning lives in one place. The legacy class's
///   `makeDefaultURLSession()` is reproduced byte-for-byte here.
/// - `URLSessionWebSocketSocket` adapts a `URLSessionWebSocketTask`
///   to the `RealtimeSocket` protocol the actor expects.
struct LiveRealtimeSessionConnector: RealtimeSessionConnector {
    let client: RecappiAPIClient
    let urlSession: URLSession

    init(client: RecappiAPIClient, urlSession: URLSession? = nil) {
        self.client = client
        self.urlSession = urlSession ?? Self.makeDefaultURLSession()
    }

    /// Default URLSession config for the live-captions WebSocket. Tuned
    /// to survive App Nap and brief network drops so the socket does
    /// not silently stall when macOS throttles the process — same
    /// configuration the legacy class installed in its own
    /// `makeDefaultURLSession()`.
    static func makeDefaultURLSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        Self.optInExtendedBackgroundIdleMode(on: config)
        return URLSession(configuration: config)
    }

    @available(macOS, deprecated: 15.4)
    private static func optInExtendedBackgroundIdleMode(on config: URLSessionConfiguration) {
        config.shouldUseExtendedBackgroundIdleMode = true
    }

    // MARK: - RealtimeSessionConnector

    func claimSession(
        mode: RealtimeLiveCaptionMode,
        language: String
    ) async throws -> RealtimeSessionClaim {
        let claim: OpenAIRealtimeSessionClaim
        switch mode {
        case .transcription:
            claim = try await client.createRealtimeTranscriptionSession(language: language)
        case .translation(let targetLanguage):
            claim = try await client.createRealtimeTranslationSession(
                language: language,
                targetLanguage: targetLanguage
            )
        }
        guard let url = URL(string: claim.websocketUrl) else {
            throw RecappiAPIError.invalidURL
        }
        return RealtimeSessionClaim(
            sessionId: claim.sessionId,
            websocketURL: url,
            token: claim.token,
            tokenType: claim.tokenType
        )
    }

    func openSocket(for claim: RealtimeSessionClaim) async throws -> RealtimeSocket {
        let request = Self.makeWebSocketRequest(for: claim, origin: client.origin)
        // Each WebSocket task gets a dedicated URLSession whose delegate
        // is the adapter, so the adapter can observe
        // `urlSession(_:webSocketTask:didCloseWith:reason:)` and signal
        // close-handshake waiters (`stop()` awaits this — Codex Finding
        // #6). The configuration is cloned off the connector's tuned
        // session so we keep App-Nap survival + waitsForConnectivity.
        let adapter = URLSessionWebSocketSocket()
        let perTaskSession = URLSession(
            configuration: urlSession.configuration,
            delegate: adapter,
            delegateQueue: nil
        )
        let task = perTaskSession.webSocketTask(with: request)
        adapter.bind(task: task, session: perTaskSession)
        task.resume()
        // Task C: emit a socket-layer trace so the diagnostics log
        // shows the WebSocket open/close handshake even when the
        // actor's traces haven't fired yet (e.g. a server-side reject
        // during the upgrade lands in `didCompleteWithError` before
        // the receive loop's first iteration).
        DiagnosticsLog.event(
            "rt-trace",
            "ws.open sid=\(claim.sessionId) host=\(claim.websocketURL.host ?? "?")"
        )
        return adapter
    }

    /// Build the `URLRequest` for the WebSocket upgrade. Carries the
    /// short-lived realtime token and the upstream `Origin` header the
    /// proxy validates before accepting the upgrade. Extracted so the
    /// request shape is testable in isolation.
    static func makeWebSocketRequest(
        for claim: RealtimeSessionClaim,
        origin: String
    ) -> URLRequest {
        var request = URLRequest(url: claim.websocketURL)
        request.timeoutInterval = 60
        request.setValue(
            "\(claim.tokenType) \(claim.token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(origin, forHTTPHeaderField: "Origin")
        return request
    }
}

// MARK: - URLSessionWebSocketTask adapter

/// `RealtimeSocket` impl backed by a `URLSessionWebSocketTask`. Receive
/// is bridged through `URLSessionWebSocketTask.receive()`'s callback-
/// style API into an `async` continuation so the actor's receive loop
/// can `await` it.
///
/// `cancel(code:reason:)` maps the int code into
/// `URLSessionWebSocketTask.CloseCode` using `init(rawValue:)`; codes
/// outside the well-known set fall through to `.invalid`, matching
/// `URLSessionWebSocketTask`'s own behaviour on a force-unmap.
final class URLSessionWebSocketSocket: NSObject, RealtimeSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _task: URLSessionWebSocketTask?
    private var _session: URLSession?
    private var _closed = false
    private var _closeWaiters: [CheckedContinuation<Void, Never>] = []

    private var task: URLSessionWebSocketTask {
        lock.lock()
        defer { lock.unlock() }
        // Safe: `bind(task:session:)` is called synchronously right
        // after init, before this property is read.
        return _task!
    }

    /// Two-phase init: the adapter is constructed first so it can be
    /// passed as the URLSession's delegate, then the task is bound
    /// after the session creates it. Without this split we couldn't
    /// install the adapter as the delegate without an Optional/IUO
    /// task reference.
    func bind(task: URLSessionWebSocketTask, session: URLSession) {
        lock.lock()
        _task = task
        _session = session
        lock.unlock()
    }

    /// Test/legacy convenience init that wires the adapter against an
    /// existing task without an owning session. Used by the connector
    /// tests that exercise the adapter's `send` / `cancel` mapping
    /// without standing up a delegate-bound session. `waitForClose()`
    /// is not driven by `didCloseWith:` in this mode — production
    /// callers must use the delegate-bound path.
    convenience init(task: URLSessionWebSocketTask) {
        self.init()
        lock.lock()
        _task = task
        lock.unlock()
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func sendPing() async throws {
        let task = self.task
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func receive() async throws -> RealtimeSocketMessage {
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return .text(text)
        case .data(let data):
            return .data(data)
        @unknown default:
            // Treat unknown frames as empty data — matches the legacy
            // class's `consume` path, which logs and drops them.
            return .data(Data())
        }
    }

    func cancel(code: Int, reason: Data?) {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .invalid
        task.cancel(with: closeCode, reason: reason)
        // Note: do NOT call `invalidateAndCancel()` on the session here.
        // The close handshake hasn't completed yet — invalidating
        // synchronously can race the close frame delivery to the
        // server. The retain-cycle break happens in `signalClosed()`
        // once `didCloseWith` (or, on timeout, `didCompleteWithError`)
        // fires, so awaiters of `waitForClose()` resolve before the
        // session is torn down.
    }

    func waitForClose() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldResolveImmediately = lock.withLock { () -> Bool in
                if _closed {
                    return true
                }
                _closeWaiters.append(continuation)
                return false
            }
            if shouldResolveImmediately {
                continuation.resume()
            }
        }
    }

    var closeCode: Int { task.closeCode.rawValue }
    var closeReason: Data? { task.closeReason }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        // Task C: socket-layer close trace. Note this adapter doesn't
        // hold the actor's `sid=` / `gen=` context, so the trace omits
        // them — the receive-loop's `ws.drop` line (emitted from the
        // actor a few ms later) does carry the sid and bridges the
        // gap. The reason payload is sanitized so a malicious
        // server-supplied reason can't break the log format.
        let reasonText: String
        if let reason, let text = String(data: reason, encoding: .utf8), !text.isEmpty {
            reasonText = DiagnosticsLog.sanitize(text, maxLength: 120)
        } else {
            reasonText = ""
        }
        DiagnosticsLog.event(
            "rt-trace",
            "ws.close code=\(closeCode.rawValue) reason='\(reasonText)'"
        )
        signalClosed()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        // didComplete fires for cancellations / transport errors that
        // didn't go through a clean close. Treat as a close for the
        // purpose of unblocking `waitForClose()`.
        signalClosed()
    }

    private func signalClosed() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            _closed = true
            let pending = _closeWaiters
            _closeWaiters.removeAll()
            return pending
        }
        for waiter in waiters {
            waiter.resume()
        }
        // After waiters resolve, break the URLSession ↔ delegate retain
        // cycle. `URLSession` strongly retains its delegate (Apple's
        // documented behaviour), and the adapter stores a back-reference
        // to the session in `_session`. Without invalidating, every
        // reconnect cycle leaks one `URLSession` + adapter pair —
        // exactly the production scenario the live-captions reconnect
        // path triggers. Invalidate AFTER signalling waiters so awaiters
        // (e.g. `stop()` blocked on `waitForClose()`) resolve first.
        invalidateOwnedSession()
    }

    /// Drop the per-socket `URLSession` so the strong reference it
    /// holds on this delegate goes away and the adapter can be
    /// collected. Called from `signalClosed()` after the close
    /// handshake (or transport completion) has fired and any awaiters
    /// of `waitForClose()` have been resolved. Idempotent under the
    /// lock — concurrent `didCloseWith` + `didCompleteWithError`
    /// callbacks race here; whichever one wins nils `_session` and
    /// invalidates; the loser sees `nil` and no-ops.
    private func invalidateOwnedSession() {
        let session: URLSession? = lock.withLock {
            let owned = _session
            _session = nil
            return owned
        }
        // `invalidateAndCancel()` — not `finishTasksAndInvalidate()` —
        // because we want any in-flight receive callback to bail out
        // immediately rather than keep the session alive until the
        // next message lands.
        session?.invalidateAndCancel()
    }

#if DEBUG
    /// Test seam: lets unit tests confirm the adapter is holding the
    /// task identity the production receive-identity guard relies on.
    var underlyingTaskForTesting: URLSessionWebSocketTask { task }

    /// Test seam: expose the per-socket URLSession reference for
    /// retain-cycle assertions. Returns `nil` after
    /// `invalidateOwnedSession()` has fired, which is exactly the
    /// signal the leak-regression test wants to assert on.
    var ownedSessionForTesting: URLSession? {
        lock.withLock { _session }
    }

    /// Test seam: drive `signalClosed()` from the test without
    /// standing up a real WebSocket connection. Mirrors what the
    /// production delegate callbacks (`didCloseWith` /
    /// `didCompleteWithError`) do — used by the leak-regression test
    /// to confirm that the close path tears down the owned session.
    func signalClosedForTesting() {
        signalClosed()
    }
#endif
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
