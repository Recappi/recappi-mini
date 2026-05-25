import Foundation

enum RecappiNetworking {
    static func makeBearerSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    static let bearerSession = makeBearerSession()
}

struct RecappiAPIClient: Sendable {
    private static let defaultSubscriptionRenewalRetryDelays: [Duration] = [
        .seconds(1),
        .seconds(2),
        .seconds(4),
        .seconds(8),
    ]

    let origin: String
    let bearerToken: String
    let session: URLSession
    let subscriptionRenewalRetryDelays: [Duration]

    init(
        origin: String,
        bearerToken: String,
        session: URLSession = RecappiNetworking.bearerSession,
        subscriptionRenewalRetryDelays: [Duration] = Self.defaultSubscriptionRenewalRetryDelays
    ) {
        self.origin = origin.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        self.bearerToken = bearerToken
        self.session = session
        self.subscriptionRenewalRetryDelays = subscriptionRenewalRetryDelays
    }

    func getSession() async throws -> SessionLookup {
        let request = try makeRequest(path: "/api/auth/get-session")
        let (data, response) = try await performValidated(request)
        return try Self.decodeSessionLookup(from: data, response: response, origin: origin)
    }

    func signOut() async throws {
        let request = try makeRequest(path: "/api/auth/sign-out", method: "POST")
        _ = try await performValidated(request)
    }

    func createRecording(
        title: String?,
        contentType: String = "audio/wav",
        durationMs: Int? = nil
    ) async throws -> CreateRecordingResponse {
        var request = try makeRequest(path: "/api/recordings", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            CreateRecordingRequest(
                title: title,
                contentType: contentType,
                durationMs: durationMs
            )
        )
        let (data, _) = try await performValidated(request, retriesSubscriptionRenewal: true)
        return try JSONDecoder().decode(CreateRecordingResponse.self, from: data)
    }

    func uploadRecording(
        recordingId: String,
        fileURL: URL,
        partSize: Int,
        progress: @escaping @MainActor @Sendable (Double) async -> Void
    ) async throws -> [UploadPartDescriptor] {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let totalBytes = max(1, (attributes[.size] as? NSNumber)?.intValue ?? 1)

        var parts: [UploadPartDescriptor] = []
        var partNumber = 1
        var uploadedBytes = 0

        while true {
            let data = try fileHandle.read(upToCount: partSize) ?? Data()
            if data.isEmpty { break }

            var request = try makeRequest(path: "/api/recordings/\(recordingId)/parts/\(partNumber)", method: "PUT")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
            request.httpBody = data

            let (responseData, _) = try await performValidated(request, allowsRetry: true)
            let uploaded = try JSONDecoder().decode(UploadedPart.self, from: responseData)
            parts.append(UploadPartDescriptor(partNumber: uploaded.partNumber, etag: uploaded.etag))

            uploadedBytes += data.count
            await progress(Double(uploadedBytes) / Double(totalBytes))
            partNumber += 1
        }

        return parts
    }

    func completeRecording(recordingId: String, parts: [UploadPartDescriptor]) async throws -> CompletedRecording {
        var request = try makeRequest(path: "/api/recordings/\(recordingId)/complete", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CompleteRecordingRequest(parts: parts))
        let (data, _) = try await performValidated(request)
        return try JSONDecoder().decode(CompletedRecording.self, from: data)
    }

    func startTranscription(
        recordingId: String,
        language: String,
        force: Bool = false,
        provider: String? = nil,
        prompt: String? = nil
    ) async throws -> StartTranscriptionResponse {
        var request = try makeRequest(path: "/api/recordings/\(recordingId)/transcribe", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            StartTranscriptionRequest(
                provider: provider,
                language: language,
                force: force,
                prompt: prompt
            )
        )
        let (data, _) = try await performValidated(request, retriesSubscriptionRenewal: true)
        return try JSONDecoder().decode(StartTranscriptionResponse.self, from: data)
    }

    func getJob(jobId: String) async throws -> TranscriptionJob {
        let request = try makeRequest(path: "/api/jobs/\(jobId)")
        let (data, _) = try await performValidated(request)
        return try JSONDecoder().decode(TranscriptionJob.self, from: data)
    }

    func listRecordingJobs(recordingId: String, limit: Int = 10) async throws -> RecordingJobsResponse {
        let request = try makeRequest(
            path: "/api/recordings/\(recordingId)/jobs",
            queryItems: [URLQueryItem(name: "limit", value: String(limit))]
        )
        let (data, _) = try await performValidated(request)
        return try JSONDecoder().decode(RecordingJobsResponse.self, from: data)
    }

    func getTranscript(recordingId: String, jobId: String) async throws -> TranscriptResponse {
        return try await getRecordingTranscript(id: recordingId, jobId: jobId)
    }

    func listRecordings(limit: Int = 20, cursor: String? = nil) async throws -> CloudRecordingsPage {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let request = try makeRequest(path: "/api/recordings", queryItems: queryItems)
        let (data, _) = try await performValidated(request)
        return try JSONDecoder().decode(CloudRecordingsPage.self, from: data)
    }

    func getRecording(id: String) async throws -> CloudRecording {
        let request = try makeRequest(path: "/api/recordings/\(id)")
        let (data, _) = try await performValidated(request)
        return try JSONDecoder().decode(CloudRecording.self, from: data)
    }

    func deleteRecording(id: String) async throws {
        let request = try makeRequest(path: "/api/recordings/\(id)", method: "DELETE")
        _ = try await performValidated(request)
    }

    func getRecordingTranscript(id: String, jobId: String? = nil) async throws -> TranscriptResponse {
        let queryItems = jobId.map { [URLQueryItem(name: "jobId", value: $0)] } ?? []
        let request = try makeRequest(path: "/api/recordings/\(id)/transcript", queryItems: queryItems)
        let (data, _) = try await performValidated(request)
        return try JSONDecoder().decode(TranscriptResponse.self, from: data)
    }

    func downloadRecordingAudio(id: String, destination: URL) async throws -> URL {
        var request = try makeRequest(path: "/api/recordings/\(id)/audio")
        request.setValue("audio/*", forHTTPHeaderField: "Accept")
        let tempURL = try await downloadValidated(request)

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    func getBillingStatus() async throws -> BillingStatus {
        let request = try makeRequest(path: "/api/billing/status")
        let (data, _) = try await performValidated(request)
        return try JSONDecoder().decode(BillingStatus.self, from: data)
    }

    func createBillingPortalSession() async throws -> BillingURLResponse {
        var request = try makeRequest(path: "/api/billing/portal", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, _) = try await performValidated(request)
        return try JSONDecoder().decode(BillingURLResponse.self, from: data)
    }

    func createBillingCheckoutSession(
        tier: BillingTier,
        successPath: String? = "/plans?status=success",
        cancelPath: String? = "/plans?status=cancel"
    ) async throws -> BillingURLResponse {
        var request = try makeRequest(path: "/api/billing/checkout", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(BillingCheckoutRequest(
            tier: tier.rawValue,
            successPath: successPath,
            cancelPath: cancelPath
        ))
        let (data, _) = try await performValidated(request)
        return try JSONDecoder().decode(BillingURLResponse.self, from: data)
    }

    func createRealtimeTranscriptionSession(language: String) async throws -> OpenAIRealtimeSessionClaim {
        var request = try makeRequest(path: "/api/openai/realtime/sessions", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OpenAIRealtimeTranscriptionSessionRequest(
                language: language,
                delay: "low",
                expiresAfterSeconds: 60,
                turnDetection: .none
            )
        )
        let (data, _) = try await performValidated(request)
        return try JSONDecoder().decode(OpenAIRealtimeSessionClaim.self, from: data)
    }

    /// Mint a bilingual (translation) Realtime session. Backend proxies
    /// the OpenAI translation endpoint and rewrites events on the way
    /// in/out; the returned `OpenAIRealtimeSessionClaim.mode` is
    /// `"translation"`.
    func createRealtimeTranslationSession(
        language: String,
        targetLanguage: String
    ) async throws -> OpenAIRealtimeSessionClaim {
        var request = try makeRequest(path: "/api/openai/realtime/sessions", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OpenAIRealtimeTranslationSessionRequest(
                language: language,
                targetLanguage: targetLanguage,
                delay: "low",
                expiresAfterSeconds: 60,
                includeSourceTranscript: true
            )
        )
        let (data, _) = try await performValidated(request)
        return try JSONDecoder().decode(OpenAIRealtimeSessionClaim.self, from: data)
    }

    func abortRecordingIfNeeded(recordingId: String) async {
        guard var request = try? makeRequest(path: "/api/recordings/\(recordingId)/abort", method: "POST") else {
            return
        }
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        _ = try? await session.data(for: request)
    }

    func performValidated(
        _ request: URLRequest,
        allowsRetry explicitAllowsRetry: Bool? = nil,
        retriesSubscriptionRenewal: Bool = false
    ) async throws -> (Data, URLResponse) {
        let allowsRetry = explicitAllowsRetry ?? Self.isIdempotent(request)
        let maxAttempts = max(
            allowsRetry ? 3 : 1,
            retriesSubscriptionRenewal ? subscriptionRenewalRetryDelays.count + 1 : 1
        )
        var attempt = 1

        while true {
            do {
                let (data, response) = try await session.data(for: request)
                try Self.validate(response: response, data: data)
                return (data, response)
            } catch {
                let shouldRetrySubscriptionRenewal =
                    retriesSubscriptionRenewal
                    && attempt <= subscriptionRenewalRetryDelays.count
                    && Self.isSubscriptionRenewalError(error)
                let shouldRetryGeneric =
                    allowsRetry
                    && attempt < maxAttempts
                    && Self.isRetryable(error)

                guard shouldRetrySubscriptionRenewal || shouldRetryGeneric else {
                    DiagnosticsLog.error(
                        "network",
                        "request.failed attempts=\(attempt) method=\(request.httpMethod ?? "GET") path=\(Self.safePath(for: request)) \(DiagnosticsLog.errorSummary(error))"
                    )
                    throw error
                }

                if shouldRetrySubscriptionRenewal {
                    DiagnosticsLog.warning(
                        "network",
                        "request.retry_subscription_renewal attempt=\(attempt) method=\(request.httpMethod ?? "GET") path=\(Self.safePath(for: request)) \(DiagnosticsLog.errorSummary(error))"
                    )
                    try await Task.sleep(for: subscriptionRenewalRetryDelays[attempt - 1])
                } else {
                    DiagnosticsLog.warning(
                        "network",
                        "request.retry attempt=\(attempt) method=\(request.httpMethod ?? "GET") path=\(Self.safePath(for: request)) \(DiagnosticsLog.errorSummary(error))"
                    )
                    try await Task.sleep(for: .milliseconds(300 * attempt))
                }
                attempt += 1
            }
        }
    }

    func downloadValidated(_ request: URLRequest) async throws -> URL {
        let maxAttempts = 3
        var attempt = 1

        while true {
            do {
                let (fileURL, response) = try await session.download(for: request)
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    defer { try? FileManager.default.removeItem(at: fileURL) }
                    let errorData = (try? Data(contentsOf: fileURL)) ?? Data()
                    try Self.validate(response: response, data: errorData)
                } else {
                    try Self.validate(response: response, data: Data())
                }
                return fileURL
            } catch {
                guard attempt < maxAttempts, Self.isRetryable(error) else {
                    DiagnosticsLog.error(
                        "network",
                        "download.failed attempts=\(attempt) method=\(request.httpMethod ?? "GET") path=\(Self.safePath(for: request)) \(DiagnosticsLog.errorSummary(error))"
                    )
                    throw error
                }
                DiagnosticsLog.warning(
                    "network",
                    "download.retry attempt=\(attempt) method=\(request.httpMethod ?? "GET") path=\(Self.safePath(for: request)) \(DiagnosticsLog.errorSummary(error))"
                )
                try await Task.sleep(for: .milliseconds(300 * attempt))
                attempt += 1
            }
        }
    }

    func makeRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(string: origin + path) else {
            throw RecappiAPIError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + queryItems
        }
        guard let url = components.url else {
            throw RecappiAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 180
        request.httpShouldHandleCookies = false
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func decodeSessionLookup(
        from data: Data,
        response: URLResponse,
        origin: String
    ) throws -> SessionLookup {
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
            return SessionLookup(userSession: nil, bearerToken: nil)
        }

        let payload = try JSONDecoder().decode(SessionEnvelope.self, from: data)
        let headerToken = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "set-auth-token")
        let resolvedToken = resolveBearerToken(headerToken: headerToken)

        guard let session = payload.session, let user = payload.user else {
            return SessionLookup(userSession: nil, bearerToken: resolvedToken)
        }

        let userSession = UserSession(
            userId: user.id,
            email: user.email,
            name: user.name,
            imageURL: user.image,
            expiresAt: session.expiresAt,
            backendOrigin: origin
        )

        return SessionLookup(userSession: userSession, bearerToken: resolvedToken)
    }

    static func resolveBearerToken(headerToken: String?) -> String? {
        guard let headerToken else { return nil }
        return AuthSessionStore.normalizeBearerToken(headerToken)
    }

    static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RecappiAPIError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw RecappiAPIError.unauthorized }
            let message = Self.extractErrorMessage(from: data)
            throw RecappiAPIError.http(statusCode: http.statusCode, message: message)
        }
    }

    private static func isIdempotent(_ request: URLRequest) -> Bool {
        switch request.httpMethod?.uppercased() ?? "GET" {
        case "GET", "HEAD":
            return true
        default:
            return false
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let apiError = error as? RecappiAPIError {
            if case .http(let statusCode, _) = apiError {
                return [408, 429, 500, 502, 503, 504].contains(statusCode)
            }
            return false
        }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorDNSLookupFailed,
        ].contains(nsError.code)
    }

    static func isSubscriptionRenewalError(_ error: Error) -> Bool {
        guard case RecappiAPIError.http(let statusCode, let message) = error,
              statusCode == 503
        else { return false }

        return message.localizedCaseInsensitiveContains("Subscription is renewing")
    }

    private static func safePath(for request: URLRequest) -> String {
        DiagnosticsLog.sanitize(request.url?.path ?? "unknown", maxLength: 160)
    }

    static func extractErrorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String {
            return message
        }
        let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return string?.isEmpty == false ? string! : "Unknown API error"
    }
}

enum RecappiAPIError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case unauthorized
    case http(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid backend URL"
        case .invalidResponse:
            return "Invalid response from Recappi backend"
        case .unauthorized:
            return "Recappi Cloud session expired. Sign in again to continue."
        case .http(let statusCode, let message):
            return "Recappi API error (status \(statusCode)): \(message)"
        }
    }
}

struct SessionLookup: Equatable {
    let userSession: UserSession?
    let bearerToken: String?
}

private struct SessionEnvelope: Decodable {
    let session: SessionPayload?
    let user: UserPayload?
}

private struct SessionPayload: Decodable {
    let expiresAt: String
    let token: String?
}

private struct UserPayload: Decodable {
    let id: String
    let email: String
    let name: String
    let image: String?
}

private struct UploadedPart: Decodable {
    let partNumber: Int
    let etag: String
}

private struct CompleteRecordingRequest: Encodable {
    let parts: [UploadPartDescriptor]
}

private struct BillingCheckoutRequest: Encodable {
    let tier: String
    let successPath: String?
    let cancelPath: String?
}
