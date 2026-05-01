import Foundation
import SQLite3

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
        do {
            if let snapshot = try loadSQLiteSnapshot(userId: userId, backendOrigin: backendOrigin) {
                return snapshot
            }
        } catch {
            NSLog("[Recappi] Cloud cache SQLite load failed: \(error.localizedDescription)")
        }

        guard let snapshot = loadLegacySnapshot(userId: userId, backendOrigin: backendOrigin) else {
            return nil
        }
        // One-way lazy migration: keep the old JSON file as a rollback
        // fallback, but make the next read hit SQLite.
        saveSnapshot(snapshot)
        return snapshot
    }

    func saveSnapshot(_ snapshot: CloudLibrarySnapshot) {
        do {
            try saveSQLiteSnapshot(snapshot)
            return
        } catch {
            NSLog("[Recappi] Cloud cache SQLite save failed: \(error.localizedDescription)")
        }

        // Last-resort compatibility fallback. Normal builds should use the
        // SQLite store; retaining JSON write keeps Cloud usable if SQLite is
        // unavailable for any unexpected system reason.
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

    private var databaseURL: URL {
        directoryURL.appendingPathComponent("cloud-cache.sqlite3", isDirectory: false)
    }

    private func loadLegacySnapshot(userId: String, backendOrigin: String) -> CloudLibrarySnapshot? {
        let url = snapshotURL(userId: userId, backendOrigin: backendOrigin)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder.cloudCache.decode(CloudLibrarySnapshot.self, from: data),
              snapshot.isCurrentVersion,
              snapshot.matches(userId: userId, backendOrigin: backendOrigin) else {
            return nil
        }
        return snapshot
    }
}

struct CloudLibrarySnapshot: Codable, Equatable, Sendable {
    /// Bumped from 1 → 2 when `transcriptCacheRecordingUpdatedAt` was added
    /// so the in-memory store could carry the freshness anchor across app
    /// launches. Snapshots with a missing version (`nil`) — encoded by the
    /// pre-version-2 build — still load via `isCurrentVersion`'s
    /// `version <= currentVersion` guard but their
    /// `transcriptCacheRecordingUpdatedAt` decodes as an empty dict, so
    /// the runtime falls back to the shape-based summary recovery in
    /// `loadTranscriptForSelection` for those records.
    static let currentVersion = 2

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

private extension CloudLibraryCache {
    func loadSQLiteSnapshot(userId: String, backendOrigin: String) throws -> CloudLibrarySnapshot? {
        try withDatabase { db in
            try createSchemaIfNeeded(db)

            let snapshotSQL = """
            SELECT version, saved_at, next_cursor, selected_recording_id, billing_status
            FROM cloud_snapshots
            WHERE user_id = ? AND backend_origin = ?
            """
            let snapshotStatement = try prepare(db, snapshotSQL)
            defer { sqlite3_finalize(snapshotStatement) }
            try bindText(snapshotStatement, 1, userId)
            try bindText(snapshotStatement, 2, backendOrigin)

            let step = sqlite3_step(snapshotStatement)
            guard step == SQLITE_ROW else {
                if step == SQLITE_DONE { return nil }
                throw SQLiteCacheError(sqliteMessage(db))
            }

            let version = Int(sqlite3_column_int(snapshotStatement, 0))
            guard version <= CloudLibrarySnapshot.currentVersion else { return nil }

            let savedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(snapshotStatement, 1))
            let nextCursor = columnText(snapshotStatement, 2)
            let selectedRecordingID = columnText(snapshotStatement, 3)
            let billingStatus = try columnData(snapshotStatement, 4)
                .flatMap { try JSONDecoder.cloudCache.decode(BillingStatusSnapshot.self, from: $0).status }

            let recordings = try loadRecordingSnapshots(db, userId: userId, backendOrigin: backendOrigin)
                .compactMap(\.cloudRecording)
            let transcriptRows = try loadTranscriptRows(db, userId: userId, backendOrigin: backendOrigin)
            let transcriptCache = transcriptRows.reduce(into: [String: TranscriptResponse]()) { result, row in
                if let transcript = row.snapshot.transcript {
                    result[row.recordingID] = transcript
                }
            }
            let transcriptCacheRecordingUpdatedAt = transcriptRows.reduce(into: [String: Date]()) { result, row in
                if let recordingUpdatedAt = row.recordingUpdatedAt {
                    result[row.recordingID] = recordingUpdatedAt
                }
            }
            let transcriptionJobsByRecordingID = try loadTranscriptionJobs(
                db,
                userId: userId,
                backendOrigin: backendOrigin
            )

            return CloudLibrarySnapshot(
                userId: userId,
                backendOrigin: backendOrigin,
                savedAt: savedAt,
                recordings: recordings,
                nextCursor: nextCursor,
                selectedRecordingID: selectedRecordingID,
                billingStatus: billingStatus,
                transcriptCache: transcriptCache,
                transcriptionJobsByRecordingID: transcriptionJobsByRecordingID,
                transcriptCacheRecordingUpdatedAt: transcriptCacheRecordingUpdatedAt,
                transcriptLimit: max(transcriptCache.count, 20)
            )
        }
    }

    func saveSQLiteSnapshot(_ snapshot: CloudLibrarySnapshot) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try withDatabase { db in
            try createSchemaIfNeeded(db)
            try execute(db, "BEGIN IMMEDIATE TRANSACTION")
            do {
                try deletePartition(db, userId: snapshot.userId, backendOrigin: snapshot.backendOrigin)
                try insertSnapshot(db, snapshot)
                try insertRecordings(db, snapshot)
                try insertTranscripts(db, snapshot)
                try insertTranscriptionJobs(db, snapshot)
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var rawDB: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &rawDB, flags, nil) == SQLITE_OK,
              let db = rawDB else {
            defer { if let rawDB { sqlite3_close(rawDB) } }
            throw SQLiteCacheError(rawDB.map(sqliteMessage) ?? "Unable to open Cloud cache database.")
        }
        defer { sqlite3_close(db) }
        try execute(db, "PRAGMA foreign_keys = ON")
        try execute(db, "PRAGMA journal_mode = WAL")
        try execute(db, "PRAGMA busy_timeout = 2000")
        return try body(db)
    }

    func createSchemaIfNeeded(_ db: OpaquePointer) throws {
        try execute(db, """
        CREATE TABLE IF NOT EXISTS cloud_snapshots (
            user_id TEXT NOT NULL,
            backend_origin TEXT NOT NULL,
            version INTEGER NOT NULL,
            saved_at REAL NOT NULL,
            next_cursor TEXT,
            selected_recording_id TEXT,
            billing_status BLOB,
            PRIMARY KEY (user_id, backend_origin)
        );
        """)
        try execute(db, """
        CREATE TABLE IF NOT EXISTS cloud_recordings (
            user_id TEXT NOT NULL,
            backend_origin TEXT NOT NULL,
            recording_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            payload BLOB NOT NULL,
            PRIMARY KEY (user_id, backend_origin, recording_id),
            FOREIGN KEY (user_id, backend_origin)
                REFERENCES cloud_snapshots(user_id, backend_origin)
                ON DELETE CASCADE
        );
        """)
        try execute(db, """
        CREATE TABLE IF NOT EXISTS cloud_transcripts (
            user_id TEXT NOT NULL,
            backend_origin TEXT NOT NULL,
            recording_id TEXT NOT NULL,
            transcript_id TEXT NOT NULL,
            recording_updated_at REAL,
            payload BLOB NOT NULL,
            PRIMARY KEY (user_id, backend_origin, recording_id),
            FOREIGN KEY (user_id, backend_origin)
                REFERENCES cloud_snapshots(user_id, backend_origin)
                ON DELETE CASCADE
        );
        """)
        try execute(db, """
        CREATE TABLE IF NOT EXISTS cloud_transcription_jobs (
            user_id TEXT NOT NULL,
            backend_origin TEXT NOT NULL,
            recording_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            job_id TEXT NOT NULL,
            payload BLOB NOT NULL,
            PRIMARY KEY (user_id, backend_origin, recording_id, position),
            FOREIGN KEY (user_id, backend_origin)
                REFERENCES cloud_snapshots(user_id, backend_origin)
                ON DELETE CASCADE
        );
        """)
        try execute(db, """
        CREATE INDEX IF NOT EXISTS idx_cloud_recordings_order
        ON cloud_recordings(user_id, backend_origin, position);
        """)
        try execute(db, """
        CREATE INDEX IF NOT EXISTS idx_cloud_jobs_order
        ON cloud_transcription_jobs(user_id, backend_origin, recording_id, position);
        """)
    }

    func deletePartition(_ db: OpaquePointer, userId: String, backendOrigin: String) throws {
        for table in ["cloud_transcription_jobs", "cloud_transcripts", "cloud_recordings", "cloud_snapshots"] {
            try run(db, "DELETE FROM \(table) WHERE user_id = ? AND backend_origin = ?") { statement in
                try bindText(statement, 1, userId)
                try bindText(statement, 2, backendOrigin)
            }
        }
    }

    func insertSnapshot(_ db: OpaquePointer, _ snapshot: CloudLibrarySnapshot) throws {
        let billingData = try snapshot.billingStatus.map { try JSONEncoder.cloudCache.encode($0) }
        try run(db, """
        INSERT INTO cloud_snapshots (
            user_id, backend_origin, version, saved_at, next_cursor,
            selected_recording_id, billing_status
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """) { statement in
            try bindText(statement, 1, snapshot.userId)
            try bindText(statement, 2, snapshot.backendOrigin)
            try bindInt(statement, 3, snapshot.version)
            try bindDouble(statement, 4, snapshot.savedAt.timeIntervalSinceReferenceDate)
            try bindText(statement, 5, snapshot.nextCursor)
            try bindText(statement, 6, snapshot.selectedRecordingID)
            try bindData(statement, 7, billingData)
        }
    }

    func insertRecordings(_ db: OpaquePointer, _ snapshot: CloudLibrarySnapshot) throws {
        let statement = try prepare(db, """
        INSERT INTO cloud_recordings (
            user_id, backend_origin, recording_id, position, payload
        ) VALUES (?, ?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(statement) }

        for (index, recording) in snapshot.recordings.enumerated() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bindText(statement, 1, snapshot.userId)
            try bindText(statement, 2, snapshot.backendOrigin)
            try bindText(statement, 3, recording.id)
            try bindInt(statement, 4, index)
            try bindData(statement, 5, JSONEncoder.cloudCache.encode(recording))
            try stepDone(statement, db)
        }
    }

    func insertTranscripts(_ db: OpaquePointer, _ snapshot: CloudLibrarySnapshot) throws {
        let statement = try prepare(db, """
        INSERT INTO cloud_transcripts (
            user_id, backend_origin, recording_id, transcript_id,
            recording_updated_at, payload
        ) VALUES (?, ?, ?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(statement) }

        for recordingID in snapshot.transcripts.keys.sorted() {
            guard let transcript = snapshot.transcripts[recordingID] else { continue }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bindText(statement, 1, snapshot.userId)
            try bindText(statement, 2, snapshot.backendOrigin)
            try bindText(statement, 3, recordingID)
            try bindText(statement, 4, transcript.id)
            try bindDouble(statement, 5, snapshot.transcriptCacheRecordingUpdatedAt?[recordingID]?.timeIntervalSinceReferenceDate)
            try bindData(statement, 6, JSONEncoder.cloudCache.encode(transcript))
            try stepDone(statement, db)
        }
    }

    func insertTranscriptionJobs(_ db: OpaquePointer, _ snapshot: CloudLibrarySnapshot) throws {
        let statement = try prepare(db, """
        INSERT INTO cloud_transcription_jobs (
            user_id, backend_origin, recording_id, position, job_id, payload
        ) VALUES (?, ?, ?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(statement) }

        for recordingID in (snapshot.transcriptionJobsByRecordingID ?? [:]).keys.sorted() {
            guard let jobs = snapshot.transcriptionJobsByRecordingID?[recordingID] else { continue }
            for (index, job) in jobs.enumerated() {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bindText(statement, 1, snapshot.userId)
                try bindText(statement, 2, snapshot.backendOrigin)
                try bindText(statement, 3, recordingID)
                try bindInt(statement, 4, index)
                try bindText(statement, 5, job.id)
                try bindData(statement, 6, JSONEncoder.cloudCache.encode(job))
                try stepDone(statement, db)
            }
        }
    }

    func loadRecordingSnapshots(
        _ db: OpaquePointer,
        userId: String,
        backendOrigin: String
    ) throws -> [CloudRecordingSnapshot] {
        try loadPayloadRows(
            db,
            sql: """
            SELECT payload FROM cloud_recordings
            WHERE user_id = ? AND backend_origin = ?
            ORDER BY position ASC
            """,
            userId: userId,
            backendOrigin: backendOrigin,
            type: CloudRecordingSnapshot.self
        )
    }

    func loadTranscriptRows(
        _ db: OpaquePointer,
        userId: String,
        backendOrigin: String
    ) throws -> [CloudTranscriptCacheRow] {
        let statement = try prepare(db, """
        SELECT recording_id, recording_updated_at, payload
        FROM cloud_transcripts
        WHERE user_id = ? AND backend_origin = ?
        ORDER BY recording_id ASC
        """)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, userId)
        try bindText(statement, 2, backendOrigin)

        var rows: [CloudTranscriptCacheRow] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw SQLiteCacheError(sqliteMessage(db)) }
            guard let data = columnData(statement, 2) else { continue }
            let recordingUpdatedAt = columnOptionalDouble(statement, 1)
                .map(Date.init(timeIntervalSinceReferenceDate:))
            rows.append(CloudTranscriptCacheRow(
                recordingID: columnText(statement, 0) ?? "",
                recordingUpdatedAt: recordingUpdatedAt,
                snapshot: try JSONDecoder.cloudCache.decode(TranscriptResponseSnapshot.self, from: data)
            ))
        }
        return rows.filter { !$0.recordingID.isEmpty }
    }

    func loadTranscriptionJobs(
        _ db: OpaquePointer,
        userId: String,
        backendOrigin: String
    ) throws -> [String: [TranscriptionJob]] {
        let statement = try prepare(db, """
        SELECT recording_id, payload
        FROM cloud_transcription_jobs
        WHERE user_id = ? AND backend_origin = ?
        ORDER BY recording_id ASC, position ASC
        """)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, userId)
        try bindText(statement, 2, backendOrigin)

        var jobsByRecordingID: [String: [TranscriptionJob]] = [:]
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw SQLiteCacheError(sqliteMessage(db)) }
            guard let recordingID = columnText(statement, 0),
                  let data = columnData(statement, 1) else { continue }
            let job = try JSONDecoder.cloudCache.decode(TranscriptionJob.self, from: data)
            jobsByRecordingID[recordingID, default: []].append(job)
        }
        return jobsByRecordingID
    }

    func loadPayloadRows<T: Decodable>(
        _ db: OpaquePointer,
        sql: String,
        userId: String,
        backendOrigin: String,
        type: T.Type
    ) throws -> [T] {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, userId)
        try bindText(statement, 2, backendOrigin)

        var values: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw SQLiteCacheError(sqliteMessage(db)) }
            guard let data = columnData(statement, 0) else { continue }
            values.append(try JSONDecoder.cloudCache.decode(T.self, from: data))
        }
        return values
    }
}

private struct CloudTranscriptCacheRow {
    let recordingID: String
    let recordingUpdatedAt: Date?
    let snapshot: TranscriptResponseSnapshot
}

private struct SQLiteCacheError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func sqliteMessage(_ db: OpaquePointer) -> String {
    guard let message = sqlite3_errmsg(db) else { return "Unknown SQLite error." }
    return String(cString: message)
}

private func execute(_ db: OpaquePointer, _ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<Int8>?
    let code = sqlite3_exec(db, sql, nil, nil, &errorMessage)
    if code != SQLITE_OK {
        let message = errorMessage.map { String(cString: $0) } ?? sqliteMessage(db)
        if let errorMessage { sqlite3_free(errorMessage) }
        throw SQLiteCacheError(message)
    }
}

private func run(
    _ db: OpaquePointer,
    _ sql: String,
    bind: (OpaquePointer) throws -> Void = { _ in }
) throws {
    let statement = try prepare(db, sql)
    defer { sqlite3_finalize(statement) }
    try bind(statement)
    try stepDone(statement, db)
}

private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw SQLiteCacheError(sqliteMessage(db))
    }
    return statement
}

private func stepDone(_ statement: OpaquePointer, _ db: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw SQLiteCacheError(sqliteMessage(db))
    }
}

private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) throws {
    let code: Int32
    if let value {
        code = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    } else {
        code = sqlite3_bind_null(statement, index)
    }
    guard code == SQLITE_OK else { throw SQLiteCacheError("Failed to bind text parameter \(index).") }
}

private func bindInt(_ statement: OpaquePointer, _ index: Int32, _ value: Int) throws {
    guard sqlite3_bind_int64(statement, index, sqlite3_int64(value)) == SQLITE_OK else {
        throw SQLiteCacheError("Failed to bind integer parameter \(index).")
    }
}

private func bindDouble(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) throws {
    let code: Int32
    if let value {
        code = sqlite3_bind_double(statement, index, value)
    } else {
        code = sqlite3_bind_null(statement, index)
    }
    guard code == SQLITE_OK else { throw SQLiteCacheError("Failed to bind double parameter \(index).") }
}

private func bindData(_ statement: OpaquePointer, _ index: Int32, _ data: Data?) throws {
    let code: Int32
    if let data {
        code = data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), sqliteTransient)
        }
    } else {
        code = sqlite3_bind_null(statement, index)
    }
    guard code == SQLITE_OK else { throw SQLiteCacheError("Failed to bind blob parameter \(index).") }
}

private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let text = sqlite3_column_text(statement, index) else {
        return nil
    }
    return String(cString: text)
}

private func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    guard count > 0 else { return Data() }
    guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
    return Data(bytes: bytes, count: count)
}

private func columnOptionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(statement, index)
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
