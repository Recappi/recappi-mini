import Foundation

struct CloudLibrarySnapshot: Codable, Equatable, Sendable {
    /// Bumped from 1 → 2 when `transcriptCacheRecordingUpdatedAt` was added
    /// so the in-memory store could carry the freshness anchor across app
    /// launches. Snapshots with a missing version (`nil`) — encoded by the
    /// pre-version-2 build — still load via `isCurrentVersion`'s
    /// `version <= currentVersion` guard but their
    /// `transcriptCacheRecordingUpdatedAt` decodes as an empty dict, so
    /// the runtime falls back to the shape-based summary recovery in
    /// `loadTranscriptForSelection` for those records.
    static let currentVersion = 3

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
    let speakerOverridesByRecordingID: [String: [String: CloudSpeakerDisplayOverride]]?
    /// Recording-level `updatedAt` captured at the moment a transcript was
    /// written into the store's `transcriptCache`. Persisted so the
    /// freshness anchor survives app restarts. Optional in the JSON to keep
    /// older snapshot files readable.
    let transcriptCacheRecordingUpdatedAt: [String: Date]?

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
        speakerOverridesByRecordingID: [String: [String: CloudSpeakerDisplayOverride]] = [:],
        transcriptCacheRecordingUpdatedAt: [String: Date] = [:],
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
        self.speakerOverridesByRecordingID = speakerOverridesByRecordingID

        var orderedIDs: [String] = []
        if let selectedRecordingID {
            orderedIDs.append(selectedRecordingID)
        }
        orderedIDs.append(contentsOf: recordings.map(\.id).filter { $0 != selectedRecordingID })
        orderedIDs.append(contentsOf: transcriptCache.keys.sorted().filter { !orderedIDs.contains($0) })

        let limitedIDs = Array(orderedIDs.prefix(transcriptLimit))
        let limitedSet = Set(limitedIDs)
        self.transcripts = limitedIDs.reduce(into: [:]) { result, id in
            if let transcript = transcriptCache[id] {
                result[id] = TranscriptResponseSnapshot(transcript)
            }
        }
        // Mirror the same scope as `transcripts`: only persist freshness
        // anchors for transcripts we are actually persisting, so the two
        // dictionaries cannot drift apart on disk.
        self.transcriptCacheRecordingUpdatedAt = transcriptCacheRecordingUpdatedAt.filter {
            limitedSet.contains($0.key)
        }
    }

    var isCurrentVersion: Bool {
        // Accept any snapshot we know how to read forward-compatibly. The
        // older v1 schema is missing only `transcriptCacheRecordingUpdatedAt`
        // (which decodes to nil → empty dict), so the v1.0.40 store can
        // still hydrate from a v1 file without forcing the user back to a
        // remote refresh on first launch.
        version <= Self.currentVersion
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

    var decodedSpeakerOverridesByRecordingID: [String: [String: CloudSpeakerDisplayOverride]] {
        speakerOverridesByRecordingID ?? [:]
    }

    var decodedTranscriptCacheRecordingUpdatedAt: [String: Date] {
        transcriptCacheRecordingUpdatedAt ?? [:]
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
    let summaryStatus: TranscriptSummaryStatus?
    let summary: String?
    let actionItems: [String]?
    let summaryInsights: TranscriptSummaryInsights?
    let segments: [TranscriptSegmentSnapshot]

    init(_ transcript: TranscriptResponse) {
        id = transcript.id
        text = transcript.text
        summaryStatus = transcript.summaryStatus
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
