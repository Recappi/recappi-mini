import Foundation

public struct RecappiCloudAPIClient: Sendable {
    public let origin: String
    public let bearerToken: String
    public let session: URLSession

    public init(
        origin: String,
        bearerToken: String,
        session: URLSession = RecappiCloudNetworking.bearerSession
    ) {
        self.origin = RecappiCloudOriginResolver.normalizeOrigin(origin)
        self.bearerToken = bearerToken
        self.session = session
    }

    public init(context: RecappiCloudAuthContext, session: URLSession = RecappiCloudNetworking.bearerSession) {
        self.init(origin: context.origin, bearerToken: context.bearerToken, session: session)
    }

    public func getSession() async throws -> RecappiCloudSession? {
        let request = try makeRequest(path: "/api/auth/get-session")
        let (data, response) = try await performValidated(request)
        return try Self.decodeSessionLookup(from: data, response: response, origin: origin).userSession
    }

    public func createRecording(
        title: String?,
        contentType: String,
        durationMs: Int?
    ) async throws -> CreateRecordingResponse {
        var request = try makeRequest(path: "/api/recordings", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            CreateRecordingRequest(title: title, contentType: contentType, durationMs: durationMs)
        )
        let (data, _) = try await performValidated(request, retriesSubscriptionRenewal: true)
        return try JSONDecoder().decode(CreateRecordingResponse.self, from: data)
    }

    public func uploadRecording(
        recordingId: String,
        fileURL: URL,
        partSize: Int,
        progress: @escaping @Sendable (Double) async -> Void
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

    public func completeRecording(
        recordingId: String,
        parts: [UploadPartDescriptor]
    ) async throws -> CompletedRecording {
        var request = try makeRequest(path: "/api/recordings/\(recordingId)/complete", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CompleteRecordingRequest(parts: parts))
        let (data, _) = try await performValidated(request)
        return try JSONDecoder().decode(CompletedRecording.self, from: data)
    }

    public func startTranscription(
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

    public func getJob(jobId: String) async throws -> RecappiCloudJob {
        let request = try makeRequest(path: "/api/jobs/\(jobId)")
        let (data, _) = try await performValidated(request)
        return try JSONDecoder().decode(RecappiCloudJob.self, from: data)
    }

    public func abortRecordingIfNeeded(recordingId: String) async {
        guard var request = try? makeRequest(path: "/api/recordings/\(recordingId)/abort", method: "POST") else {
            return
        }
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        _ = try? await session.data(for: request)
    }

    public func makeRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(string: origin + path) else {
            throw RecappiCloudError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + queryItems
        }
        guard let url = components.url else {
            throw RecappiCloudError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 180
        request.httpShouldHandleCookies = false
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func performValidated(
        _ request: URLRequest,
        allowsRetry explicitAllowsRetry: Bool? = nil,
        retriesSubscriptionRenewal: Bool = false
    ) async throws -> (Data, URLResponse) {
        let allowsRetry = explicitAllowsRetry ?? Self.isIdempotent(request)
        let renewalDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
        let maxAttempts = max(
            allowsRetry ? 3 : 1,
            retriesSubscriptionRenewal ? renewalDelays.count + 1 : 1
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
                    && attempt <= renewalDelays.count
                    && Self.isSubscriptionRenewalError(error)
                let shouldRetryGeneric =
                    allowsRetry
                    && attempt < maxAttempts
                    && Self.isRetryable(error)

                guard shouldRetrySubscriptionRenewal || shouldRetryGeneric else {
                    throw error
                }

                if shouldRetrySubscriptionRenewal {
                    try await Task.sleep(for: renewalDelays[attempt - 1])
                } else {
                    try await Task.sleep(for: .milliseconds(300 * attempt))
                }
                attempt += 1
            }
        }
    }

    public static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RecappiCloudError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw RecappiCloudError.unauthorized }
            throw RecappiCloudError.http(
                statusCode: http.statusCode,
                message: extractErrorMessage(from: data)
            )
        }
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
        let resolvedToken = RecappiCloudCredentialStore.normalizeBearerToken(headerToken)

        guard let session = payload.session, let user = payload.user else {
            return SessionLookup(userSession: nil, bearerToken: resolvedToken)
        }

        return SessionLookup(
            userSession: RecappiCloudSession(
                userId: user.id,
                email: user.email,
                name: user.name,
                imageURL: user.image,
                expiresAt: session.expiresAt,
                backendOrigin: origin
            ),
            bearerToken: resolvedToken
        )
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
        if let apiError = error as? RecappiCloudError {
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

    private static func isSubscriptionRenewalError(_ error: Error) -> Bool {
        guard case RecappiCloudError.http(let statusCode, let message) = error,
              statusCode == 503
        else { return false }

        return message.localizedCaseInsensitiveContains("Subscription is renewing")
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

public enum RecappiCloudNetworking {
    public static func makeBearerSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    public static let bearerSession = makeBearerSession()
}

public struct CreateRecordingRequest: Encodable, Sendable {
    let title: String?
    let contentType: String
    let durationMs: Int?
}

public struct CreateRecordingResponse: Decodable, Equatable, Sendable {
    public let id: String
    public let partSize: Int
    public let maxPartBytes: Int
    public let r2Key: String
}

public struct UploadPartDescriptor: Codable, Equatable, Sendable {
    public let partNumber: Int
    public let etag: String
}

public struct CompletedRecording: Decodable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let contentType: String
}

public struct StartTranscriptionRequest: Encodable, Sendable {
    let provider: String?
    let language: String
    let force: Bool
    let prompt: String?
}

public struct StartTranscriptionResponse: Decodable, Equatable, Sendable {
    public let jobId: String
    public let status: RecappiCloudJobStatus
    public let transcriptId: String?
}

struct SessionLookup: Equatable, Sendable {
    let userSession: RecappiCloudSession?
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
