import Foundation

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

enum CloudRecordingDisplayStatus: Equatable, Sendable {
    case recording(CloudRecordingStatus)
    case transcription(RemoteJobStatus)

    static func resolve(
        recordingStatus: CloudRecordingStatus,
        latestJobStatus: RemoteJobStatus?
    ) -> CloudRecordingDisplayStatus {
        switch latestJobStatus {
        case .queued?:
            return .transcription(.queued)
        case .running?:
            return .transcription(.running)
        case .failed?:
            return .transcription(.failed)
        case .succeeded, nil:
            return .recording(recordingStatus)
        }
    }

    var displayName: String {
        switch self {
        case .recording(let status):
            return status.displayName
        case .transcription(let status):
            return status.displayName
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

enum RecappiDateDecoder {
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
    let totalCount: Int?
}
