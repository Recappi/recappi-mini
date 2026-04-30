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

    func startTranscription(
        recordingId: String,
        language: String,
        force: Bool = false,
        provider: String? = nil
    ) async throws -> StartTranscriptionResponse {
        var request = try makeRequest(path: "/api/recordings/\(recordingId)/transcribe", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let prompt = force ? "Run a fresh transcription pass with the default Recappi instructions." : nil
        request.httpBody = try JSONEncoder().encode(
            StartTranscriptionRequest(provider: provider, language: language, force: force, prompt: prompt)
        )
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

    func listRecordingJobs(recordingId: String, limit: Int = 10) async throws -> RecordingJobsResponse {
        let request = try makeRequest(
            path: "/api/recordings/\(recordingId)/jobs",
            queryItems: [URLQueryItem(name: "limit", value: String(limit))]
        )
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
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
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(CloudRecordingsPage.self, from: data)
    }

    func getRecording(id: String) async throws -> CloudRecording {
        let request = try makeRequest(path: "/api/recordings/\(id)")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(CloudRecording.self, from: data)
    }

    func deleteRecording(id: String) async throws {
        let request = try makeRequest(path: "/api/recordings/\(id)", method: "DELETE")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
    }

    func getRecordingTranscript(id: String, jobId: String? = nil) async throws -> TranscriptResponse {
        let queryItems = jobId.map { [URLQueryItem(name: "jobId", value: $0)] } ?? []
        let request = try makeRequest(path: "/api/recordings/\(id)/transcript", queryItems: queryItems)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(TranscriptResponse.self, from: data)
    }

    func downloadRecordingAudio(id: String, destination: URL) async throws -> URL {
        var request = try makeRequest(path: "/api/recordings/\(id)/audio")
        request.setValue("audio/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }

    func getBillingStatus() async throws -> BillingStatus {
        let request = try makeRequest(path: "/api/billing/status")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(BillingStatus.self, from: data)
    }

    func createBillingPortalSession() async throws -> BillingURLResponse {
        var request = try makeRequest(path: "/api/billing/portal", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
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
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(BillingURLResponse.self, from: data)
    }

    func abortRecordingIfNeeded(recordingId: String) async {
        guard var request = try? makeRequest(path: "/api/recordings/\(recordingId)/abort", method: "POST") else {
            return
        }
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        _ = try? await session.data(for: request)
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

enum CloudRecordingStatus: Equatable, Sendable, Decodable {
    case uploading
    case ready
    case failed
    case aborted
    case unknown(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "uploading": self = .uploading
        case "ready": self = .ready
        case "failed": self = .failed
        case "aborted": self = .aborted
        default: self = .unknown(value)
        }
    }

    var rawValue: String {
        switch self {
        case .uploading: return "uploading"
        case .ready: return "ready"
        case .failed: return "failed"
        case .aborted: return "aborted"
        case .unknown(let value): return value
        }
    }

    var displayName: String {
        switch self {
        case .uploading: return "Uploading"
        case .ready: return "Ready"
        case .failed: return "Failed"
        case .aborted: return "Aborted"
        case .unknown(let value): return value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var allowsTranscriptionRequest: Bool {
        switch self {
        case .uploading, .aborted:
            return false
        case .ready, .failed, .unknown:
            return true
        }
    }
}

struct CloudRecording: Identifiable, Decodable, Equatable, Sendable {
    let id: String
    let userId: String?
    let title: String?
    let summaryTitle: String?
    let sourceTitle: String?
    let sourceAppName: String?
    let sourceAppBundleID: String?
    let r2Key: String?
    let r2UploadId: String?
    let status: CloudRecordingStatus
    let sizeBytes: Int64?
    let durationMs: Int?
    let sampleRate: Int?
    let channels: Int?
    let contentType: String?
    let activeTranscriptId: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(
        id: String,
        userId: String?,
        title: String?,
        summaryTitle: String?,
        sourceTitle: String?,
        sourceAppName: String?,
        sourceAppBundleID: String?,
        r2Key: String?,
        r2UploadId: String?,
        status: CloudRecordingStatus,
        sizeBytes: Int64?,
        durationMs: Int?,
        sampleRate: Int?,
        channels: Int?,
        contentType: String?,
        activeTranscriptId: String?,
        createdAt: Date?,
        updatedAt: Date?
    ) {
        self.id = id
        self.userId = userId
        self.title = title
        self.summaryTitle = summaryTitle
        self.sourceTitle = sourceTitle
        self.sourceAppName = sourceAppName
        self.sourceAppBundleID = sourceAppBundleID
        self.r2Key = r2Key
        self.r2UploadId = r2UploadId
        self.status = status
        self.sizeBytes = sizeBytes
        self.durationMs = durationMs
        self.sampleRate = sampleRate
        self.channels = channels
        self.contentType = contentType
        self.activeTranscriptId = activeTranscriptId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId
        case title
        case summaryTitle
        case meetingTitle
        case sourceTitle
        case source
        case sourceAppName
        case sourceApp
        case appName
        case application
        case app
        case sourceAppBundleID
        case sourceBundleID
        case bundleID
        case bundleId
        case metadata
        case r2Key
        case r2UploadId
        case status
        case sizeBytes
        case durationMs
        case sampleRate
        case channels
        case contentType
        case activeTranscriptId
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        let metadata = try container.decodeIfPresent(CloudRecordingMetadata.self, forKey: .metadata)
        let directSummaryTitle = container.decodeFirstString(forKeys: [.summaryTitle, .meetingTitle])
        summaryTitle = directSummaryTitle ?? Self.firstString([
            metadata?.summaryTitle,
            metadata?.meetingTitle,
        ])

        let directSourceTitle = container.decodeFirstString(forKeys: [.sourceTitle, .source])
        sourceTitle = directSourceTitle ?? Self.firstString([
            metadata?.sourceTitle,
            metadata?.source,
        ])

        let directSourceAppName = container.decodeFirstString(forKeys: [.sourceAppName, .sourceApp, .appName, .application, .app])
        sourceAppName = directSourceAppName ?? Self.firstString([
            metadata?.sourceAppName,
            metadata?.sourceApp,
            metadata?.appName,
            metadata?.application,
            metadata?.app,
        ])

        let directSourceBundleID = container.decodeFirstString(forKeys: [.sourceAppBundleID, .sourceBundleID, .bundleID, .bundleId])
        sourceAppBundleID = directSourceBundleID ?? Self.firstString([
            metadata?.sourceAppBundleID,
            metadata?.sourceBundleID,
            metadata?.bundleID,
            metadata?.bundleId,
        ])
        r2Key = try container.decodeIfPresent(String.self, forKey: .r2Key)
        r2UploadId = try container.decodeIfPresent(String.self, forKey: .r2UploadId)
        status = try container.decode(CloudRecordingStatus.self, forKey: .status)
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        sampleRate = try container.decodeIfPresent(Int.self, forKey: .sampleRate)
        channels = try container.decodeIfPresent(Int.self, forKey: .channels)
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
        activeTranscriptId = try container.decodeIfPresent(String.self, forKey: .activeTranscriptId)
        createdAt = RecappiDateDecoder.decodeDateIfPresent(from: container, forKey: .createdAt)
        updatedAt = RecappiDateDecoder.decodeDateIfPresent(from: container, forKey: .updatedAt)
    }

    private static func firstString(_ values: [String?]) -> String? {
        values.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    func mergingCachedDetail(from cached: CloudRecording) -> CloudRecording {
        CloudRecording(
            id: id,
            userId: userId ?? cached.userId,
            title: title ?? cached.title,
            summaryTitle: summaryTitle ?? cached.summaryTitle,
            sourceTitle: sourceTitle ?? cached.sourceTitle,
            sourceAppName: sourceAppName ?? cached.sourceAppName,
            sourceAppBundleID: sourceAppBundleID ?? cached.sourceAppBundleID,
            r2Key: r2Key ?? cached.r2Key,
            r2UploadId: r2UploadId ?? cached.r2UploadId,
            status: status,
            sizeBytes: sizeBytes ?? cached.sizeBytes,
            durationMs: durationMs ?? cached.durationMs,
            sampleRate: sampleRate ?? cached.sampleRate,
            channels: channels ?? cached.channels,
            contentType: contentType ?? cached.contentType,
            activeTranscriptId: activeTranscriptId ?? cached.activeTranscriptId,
            createdAt: createdAt ?? cached.createdAt,
            updatedAt: updatedAt ?? cached.updatedAt
        )
    }
}

private struct CloudRecordingMetadata: Decodable, Equatable, Sendable {
    let summaryTitle: String?
    let meetingTitle: String?
    let sourceTitle: String?
    let source: String?
    let sourceAppName: String?
    let sourceApp: String?
    let appName: String?
    let application: String?
    let app: String?
    let sourceAppBundleID: String?
    let sourceBundleID: String?
    let bundleID: String?
    let bundleId: String?
}

private extension KeyedDecodingContainer where Key == CloudRecording.CodingKeys {
    func decodeFirstString(forKeys keys: [Key]) -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }
}

private enum RecappiDateDecoder {
    static func decodeDateIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> Date? {
        if let milliseconds = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: normalizeTimestamp(milliseconds))
        }

        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }

        if let numeric = Double(raw) {
            return Date(timeIntervalSince1970: normalizeTimestamp(numeric))
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func normalizeTimestamp(_ raw: Double) -> TimeInterval {
        raw > 10_000_000_000 ? raw / 1000 : raw
    }
}

struct CloudRecordingsPage: Decodable, Equatable, Sendable {
    let items: [CloudRecording]
    let nextCursor: String?
}

enum BillingTier: String, CaseIterable, Codable, Equatable, Sendable {
    case free
    case starter
    case pro
    case business
    case unlimited

    var displayName: String {
        switch self {
        case .free: return "Free"
        case .starter: return "Starter"
        case .pro: return "Pro"
        case .business: return "Business"
        case .unlimited: return "Unlimited"
        }
    }
}

struct BillingStatus: Decodable, Equatable, Sendable {
    let tier: BillingTier
    let periodStart: Date?
    let periodEnd: Date?
    let storageBytes: Int64
    let storageCapBytes: Int64
    let minutesUsed: Double
    let minutesCap: Double
    let isOverStorage: Bool
    let isOverMinutes: Bool

    enum CodingKeys: String, CodingKey {
        case tier
        case periodStart
        case periodEnd
        case storageBytes
        case storageCapBytes
        case minutesUsed
        case minutesCap
        case isOverStorage
        case isOverMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tier = try container.decode(BillingTier.self, forKey: .tier)
        periodStart = RecappiDateDecoder.decodeDateIfPresent(from: container, forKey: .periodStart)
        periodEnd = RecappiDateDecoder.decodeDateIfPresent(from: container, forKey: .periodEnd)
        storageBytes = try container.decode(Int64.self, forKey: .storageBytes)
        storageCapBytes = try container.decodeIfPresent(Int64.self, forKey: .storageCapBytes) ?? 0
        minutesUsed = try container.decode(Double.self, forKey: .minutesUsed)
        minutesCap = try container.decodeIfPresent(Double.self, forKey: .minutesCap) ?? 0
        isOverStorage = try container.decode(Bool.self, forKey: .isOverStorage)
        isOverMinutes = try container.decode(Bool.self, forKey: .isOverMinutes)
    }

    var hasUnlimitedStorage: Bool {
        tier == .unlimited || storageCapBytes <= 0
    }

    var hasUnlimitedMinutes: Bool {
        tier == .unlimited || minutesCap <= 0
    }

    var effectiveIsOverStorage: Bool {
        !hasUnlimitedStorage && isOverStorage
    }

    var effectiveIsOverMinutes: Bool {
        !hasUnlimitedMinutes && isOverMinutes
    }

    var effectiveIsOverAnyLimit: Bool {
        effectiveIsOverStorage || effectiveIsOverMinutes
    }
}

struct BillingURLResponse: Decodable, Equatable, Sendable {
    let url: String
}

private struct BillingCheckoutRequest: Encodable {
    let tier: String
    let successPath: String?
    let cancelPath: String?
}

struct StartTranscriptionRequest: Encodable {
    let provider: String?
    let language: String
    let force: Bool
    let prompt: String?
}

enum RemoteJobStatus: String, Codable, Equatable {
    case queued
    case running
    case succeeded
    case failed

    var isActive: Bool {
        self == .queued || self == .running
    }
}

struct StartTranscriptionResponse: Decodable {
    let jobId: String
    let status: RemoteJobStatus
    let transcriptId: String?
}

struct RecordingJobsResponse: Decodable, Equatable, Sendable {
    let items: [TranscriptionJob]
}

struct TranscriptionJob: Codable, Equatable, Sendable {
    let id: String
    let status: RemoteJobStatus
    let transcriptId: String?
    let provider: String
    let model: String
    let language: String?
    let prompt: String?
    let error: String?
    let attempts: Int?
    let enqueuedAt: Int?
    let startedAt: Int?
    let finishedAt: Int?
}

struct TranscriptResponse: Decodable, Equatable, Sendable {
    let id: String
    let text: String
    let summary: String?
    let actionItems: [String]?
    let segments: [TranscriptSegment]

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case summary
        case actionItems
        case actionItemsJson
        case segments
        case segmentsJson
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)

        let decodedSegments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments)
            ?? Self.decodeSegmentsJSON(try container.decodeIfPresent(String.self, forKey: .segmentsJson))
            ?? []
        segments = Self.normalizeSegmentTimeline(
            decodedSegments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )

        let decodedText = try container.decodeIfPresent(String.self, forKey: .text)
        text = decodedText ?? segments.map(\.text).joined(separator: "\n")
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        let decodedActionItems = try container.decodeIfPresent([String].self, forKey: .actionItems)
            ?? Self.decodeActionItemsJSON(try container.decodeIfPresent(String.self, forKey: .actionItemsJson))
        actionItems = decodedActionItems.map(Self.normalizeActionItems)
    }

    private static func decodeSegmentsJSON(_ raw: String?) -> [TranscriptSegment]? {
        guard let raw,
              let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([TranscriptSegment].self, from: data)
    }

    private static func decodeActionItemsJSON(_ raw: String?) -> [String]? {
        guard let raw else { return nil }
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return normalizeActionItems(decoded)
    }

    private static func normalizeActionItems(_ items: [String]) -> [String] {
        items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeSegmentTimeline(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let durations = segments.compactMap { segment -> Int? in
            guard let start = segment.startMs, let end = segment.endMs, end > start else { return nil }
            return end - start
        }
        guard let maxEnd = segments.compactMap(\.endMs).max(),
              let medianDuration = durations.sorted().dropFirst(durations.count / 2).first,
              maxEnd < 24 * 60 * 60,
              medianDuration <= 120 else {
            return segments
        }

        return segments.map { $0.scalingTimeline(by: 1000) }
    }
}

struct TranscriptSegment: Decodable, Equatable, Sendable {
    let startMs: Int?
    let endMs: Int?
    let text: String
    let speaker: String?

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case startMs
        case endMs
        case startTimeMs
        case endTimeMs
        case text
        case speaker
        case speakerLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startMs = Self.decodeMilliseconds(from: container, keys: [.startMs, .startTimeMs, .start])
        endMs = Self.decodeMilliseconds(from: container, keys: [.endMs, .endTimeMs, .end])
        text = (try container.decodeIfPresent(String.self, forKey: .text)) ?? ""
        speaker = container.decodeFirstString(forKeys: [.speaker, .speakerLabel])
    }

    private init(startMs: Int?, endMs: Int?, text: String, speaker: String?) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speaker = speaker
    }

    func scalingTimeline(by factor: Int) -> TranscriptSegment {
        TranscriptSegment(
            startMs: startMs.map { $0 * factor },
            endMs: endMs.map { $0 * factor },
            text: text,
            speaker: speaker
        )
    }

    private static func decodeMilliseconds(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Int(value.rounded())
            }
            if let raw = try? container.decodeIfPresent(String.self, forKey: key),
               let value = Double(raw) {
                return Int(value.rounded())
            }
        }
        return nil
    }
}

private extension KeyedDecodingContainer where Key == TranscriptSegment.CodingKeys {
    func decodeFirstString(forKeys keys: [Key]) -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}
