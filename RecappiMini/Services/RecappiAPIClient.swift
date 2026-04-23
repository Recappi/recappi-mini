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
    let origin: String
    let bearerToken: String
    let session: URLSession

    init(origin: String, bearerToken: String, session: URLSession = RecappiNetworking.bearerSession) {
        self.origin = origin.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        self.bearerToken = bearerToken
        self.session = session
    }

    func getSession() async throws -> SessionLookup {
        let request = try makeRequest(path: "/api/auth/get-session")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try Self.decodeSessionLookup(from: data, response: response, origin: origin)
    }

    func signOut() async throws {
        let request = try makeRequest(path: "/api/auth/sign-out", method: "POST")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
    }

    func createRecording(title: String?) async throws -> CreateRecordingResponse {
        var request = try makeRequest(path: "/api/recordings", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CreateRecordingRequest(title: title))
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
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

            let (responseData, response) = try await session.data(for: request)
            try Self.validate(response: response, data: responseData)
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
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(CompletedRecording.self, from: data)
    }

    func startTranscription(recordingId: String, language: String) async throws -> StartTranscriptionResponse {
        var request = try makeRequest(path: "/api/recordings/\(recordingId)/transcribe", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(StartTranscriptionRequest(language: language))
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(StartTranscriptionResponse.self, from: data)
    }

    func getJob(jobId: String) async throws -> TranscriptionJob {
        let request = try makeRequest(path: "/api/jobs/\(jobId)")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(TranscriptionJob.self, from: data)
    }

    func getTranscript(recordingId: String, jobId: String) async throws -> TranscriptResponse {
        let request = try makeRequest(path: "/api/recordings/\(recordingId)/transcript?jobId=\(jobId)")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(TranscriptResponse.self, from: data)
    }

    func abortRecordingIfNeeded(recordingId: String) async {
        guard var request = try? makeRequest(path: "/api/recordings/\(recordingId)/abort", method: "POST") else {
            return
        }
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        _ = try? await session.data(for: request)
    }

    private func makeRequest(path: String, method: String = "GET") throws -> URLRequest {
        guard let url = URL(string: origin + path) else {
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

private struct CreateRecordingRequest: Encodable {
    let title: String?
}

struct CreateRecordingResponse: Decodable {
    let id: String
    let partSize: Int
    let maxPartBytes: Int
    let r2Key: String
}

struct UploadPartDescriptor: Codable, Equatable {
    let partNumber: Int
    let etag: String
}

private struct UploadedPart: Decodable {
    let partNumber: Int
    let etag: String
}

private struct CompleteRecordingRequest: Encodable {
    let parts: [UploadPartDescriptor]
}

struct CompletedRecording: Decodable {
    let id: String
    let status: String
    let contentType: String
}

private struct StartTranscriptionRequest: Encodable {
    let language: String
}

enum RemoteJobStatus: String, Decodable, Equatable {
    case queued
    case running
    case succeeded
    case failed
}

struct StartTranscriptionResponse: Decodable {
    let jobId: String
    let status: RemoteJobStatus
    let transcriptId: String?
}

struct TranscriptionJob: Decodable {
    let id: String
    let status: RemoteJobStatus
    let transcriptId: String?
    let provider: String
    let model: String
    let error: String?
}

struct TranscriptResponse: Decodable {
    let id: String
    let text: String
}
