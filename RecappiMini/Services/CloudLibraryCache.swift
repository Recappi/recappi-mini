import Foundation

actor CloudLibraryCache {
    static let shared = CloudLibraryCache()

    private let directoryURL: URL
    private let fileManager: FileManager

    init(
        directoryURL: URL = CloudLibraryCache.defaultDirectoryURL(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    func loadSnapshot(userId: String, backendOrigin: String) -> CloudLibrarySnapshot? {
        let url = snapshotURL(userId: userId, backendOrigin: backendOrigin)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder.cloudCache.decode(CloudLibrarySnapshot.self, from: data),
              snapshot.isCurrentVersion,
              snapshot.matches(userId: userId, backendOrigin: backendOrigin) else {
            return nil
        }
        return snapshot
    }

    func saveSnapshot(_ snapshot: CloudLibrarySnapshot) {
        let url = snapshotURL(userId: snapshot.userId, backendOrigin: snapshot.backendOrigin)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder.cloudCache.encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("[Recappi] Cloud cache save failed: \(error.localizedDescription)")
        }
    }

    nonisolated static func defaultDirectoryURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("Recappi Mini", isDirectory: true)
            .appendingPathComponent("CloudCache", isDirectory: true)
    }

    nonisolated static func cacheFilename(userId: String, backendOrigin: String) -> String {
        let raw = "\(backendOrigin)::\(userId)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(sanitized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String(collapsed.prefix(120)) + ".json"
    }

    private func snapshotURL(userId: String, backendOrigin: String) -> URL {
        directoryURL.appendingPathComponent(
            Self.cacheFilename(userId: userId, backendOrigin: backendOrigin),
            isDirectory: false
        )
    }
}

struct CloudLibrarySnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let userId: String
    let backendOrigin: String
    let savedAt: Date
    let recordings: [CloudRecordingSnapshot]
    let nextCursor: String?
    let selectedRecordingID: String?
    let billingStatus: BillingStatusSnapshot?
    let transcripts: [String: TranscriptResponseSnapshot]
    let transcriptionJobsByRecordingID: [String: [TranscriptionJob]]?

    init(
        userId: String,
        backendOrigin: String,
        savedAt: Date,
        recordings: [CloudRecording],
        nextCursor: String?,
        selectedRecordingID: String?,
        billingStatus: BillingStatus?,
        transcriptCache: [String: TranscriptResponse],
        transcriptionJobsByRecordingID: [String: [TranscriptionJob]] = [:],
        transcriptLimit: Int = 20
    ) {
        self.version = Self.currentVersion
        self.userId = userId
        self.backendOrigin = backendOrigin
        self.savedAt = savedAt
        self.recordings = recordings.map(CloudRecordingSnapshot.init)
        self.nextCursor = nextCursor
        self.selectedRecordingID = selectedRecordingID
        self.billingStatus = billingStatus.map(BillingStatusSnapshot.init)
        self.transcriptionJobsByRecordingID = transcriptionJobsByRecordingID

        var orderedIDs: [String] = []
        if let selectedRecordingID {
            orderedIDs.append(selectedRecordingID)
        }
        orderedIDs.append(contentsOf: recordings.map(\.id).filter { $0 != selectedRecordingID })
        orderedIDs.append(contentsOf: transcriptCache.keys.sorted().filter { !orderedIDs.contains($0) })

        self.transcripts = orderedIDs.prefix(transcriptLimit).reduce(into: [:]) { result, id in
            if let transcript = transcriptCache[id] {
                result[id] = TranscriptResponseSnapshot(transcript)
            }
        }
    }

    var isCurrentVersion: Bool {
        version == Self.currentVersion
    }

    func matches(userId: String, backendOrigin: String) -> Bool {
        self.userId == userId && self.backendOrigin == backendOrigin
    }

    var decodedRecordings: [CloudRecording] {
        recordings.compactMap(\.cloudRecording)
    }

    var decodedBillingStatus: BillingStatus? {
        billingStatus?.status
    }

    var decodedTranscripts: [String: TranscriptResponse] {
        transcripts.compactMapValues(\.transcript)
    }

    var decodedTranscriptionJobsByRecordingID: [String: [TranscriptionJob]] {
        transcriptionJobsByRecordingID ?? [:]
    }
}

struct CloudRecordingSnapshot: Codable, Equatable, Sendable {
    let id: String
    let userId: String?
    let title: String?
    let summaryTitle: String?
    let sourceTitle: String?
    let sourceAppName: String?
    let sourceAppBundleID: String?
    let r2Key: String?
    let r2UploadId: String?
    let status: String
    let sizeBytes: Int64?
    let durationMs: Int?
    let sampleRate: Int?
    let channels: Int?
    let contentType: String?
    let activeTranscriptId: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(_ recording: CloudRecording) {
        id = recording.id
        userId = recording.userId
        title = recording.title
        summaryTitle = recording.summaryTitle
        sourceTitle = recording.sourceTitle
        sourceAppName = recording.sourceAppName
        sourceAppBundleID = recording.sourceAppBundleID
        r2Key = recording.r2Key
        r2UploadId = recording.r2UploadId
        status = recording.status.rawValue
        sizeBytes = recording.sizeBytes
        durationMs = recording.durationMs
        sampleRate = recording.sampleRate
        channels = recording.channels
        contentType = recording.contentType
        activeTranscriptId = recording.activeTranscriptId
        createdAt = recording.createdAt
        updatedAt = recording.updatedAt
    }

    var cloudRecording: CloudRecording? {
        decodeViaAPIModel(CloudRecording.self, from: self)
    }
}

struct BillingStatusSnapshot: Codable, Equatable, Sendable {
    let tier: BillingTier
    let periodStart: Date?
    let periodEnd: Date?
    let storageBytes: Int64
    let storageCapBytes: Int64
    let minutesUsed: Double
    let minutesCap: Double
    let isOverStorage: Bool
    let isOverMinutes: Bool

    init(_ status: BillingStatus) {
        tier = status.tier
        periodStart = status.periodStart
        periodEnd = status.periodEnd
        storageBytes = status.storageBytes
        storageCapBytes = status.storageCapBytes
        minutesUsed = status.minutesUsed
        minutesCap = status.minutesCap
        isOverStorage = status.isOverStorage
        isOverMinutes = status.isOverMinutes
    }

    var status: BillingStatus? {
        decodeViaAPIModel(BillingStatus.self, from: self)
    }
}

struct TranscriptResponseSnapshot: Codable, Equatable, Sendable {
    let id: String
    let text: String
    let summary: String?
    let actionItems: [String]?
    let summaryInsights: TranscriptSummaryInsights?
    let segments: [TranscriptSegmentSnapshot]

    init(_ transcript: TranscriptResponse) {
        id = transcript.id
        text = transcript.text
        summary = transcript.summary
        actionItems = transcript.actionItems
        summaryInsights = transcript.summaryInsights
        segments = transcript.segments.map(TranscriptSegmentSnapshot.init)
    }

    var transcript: TranscriptResponse? {
        decodeViaAPIModel(TranscriptResponse.self, from: self)
    }
}

struct TranscriptSegmentSnapshot: Codable, Equatable, Sendable {
    let startMs: Int?
    let endMs: Int?
    let text: String
    let speaker: String?

    init(_ segment: TranscriptSegment) {
        startMs = segment.startMs
        endMs = segment.endMs
        text = segment.text
        speaker = segment.speaker
    }
}

private func decodeViaAPIModel<T: Decodable, Source: Encodable>(
    _ type: T.Type,
    from source: Source
) -> T? {
    guard let data = try? JSONEncoder.cloudCache.encode(source) else { return nil }
    return try? JSONDecoder.cloudCache.decode(type, from: data)
}

private extension JSONEncoder {
    static var cloudCache: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var cloudCache: JSONDecoder {
        JSONDecoder()
    }
}
