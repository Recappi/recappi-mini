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
                DiagnosticsLog.event("cloud-cache", "snapshot.load.sqlite userHash=\(userId.hashValue) originHash=\(backendOrigin.hashValue)")
                return snapshot
            }
        } catch {
            DiagnosticsLog.warning("cloud-cache", "snapshot.load.sqlite_failed \(DiagnosticsLog.errorSummary(error))")
        }

        guard let snapshot = loadLegacySnapshot(userId: userId, backendOrigin: backendOrigin) else {
            DiagnosticsLog.event("cloud-cache", "snapshot.load.miss userHash=\(userId.hashValue) originHash=\(backendOrigin.hashValue)")
            return nil
        }
        // One-way lazy migration: keep the old JSON file as a rollback
        // fallback, but make the next read hit SQLite.
        DiagnosticsLog.event("cloud-cache", "snapshot.load.legacy userHash=\(userId.hashValue) originHash=\(backendOrigin.hashValue)")
        saveSnapshot(snapshot)
        return snapshot
    }

    func saveSnapshot(_ snapshot: CloudLibrarySnapshot) {
        do {
            try saveSQLiteSnapshot(snapshot)
            DiagnosticsLog.event(
                "cloud-cache",
                "snapshot.save.sqlite userHash=\(snapshot.userId.hashValue) count=\(snapshot.recordings.count)"
            )
            return
        } catch {
            DiagnosticsLog.warning("cloud-cache", "snapshot.save.sqlite_failed \(DiagnosticsLog.errorSummary(error))")
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
            DiagnosticsLog.error("cloud-cache", "snapshot.save.legacy_failed \(DiagnosticsLog.errorSummary(error))")
        }
    }

    func searchCachedRecordings(
        userId: String,
        backendOrigin: String,
        query: String,
        speakerRawName: String? = nil,
        limit: Int = 50
    ) throws -> [CloudIndexedSearchResult] {
        try withDatabase { db in
            try createSchemaIfNeeded(db)
            return try searchSQLiteIndex(
                db,
                userId: userId,
                backendOrigin: backendOrigin,
                query: query,
                speakerRawName: speakerRawName,
                limit: limit
            )
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
            let speakerOverridesByRecordingID = try loadSpeakerOverrides(
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
                speakerOverridesByRecordingID: speakerOverridesByRecordingID,
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
                try insertSpeakerOverrides(db, snapshot)
                try rebuildSearchIndex(db, snapshot)
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
        CREATE TABLE IF NOT EXISTS cloud_speaker_overrides (
            user_id TEXT NOT NULL,
            backend_origin TEXT NOT NULL,
            recording_id TEXT NOT NULL,
            speaker_id TEXT NOT NULL,
            payload BLOB NOT NULL,
            PRIMARY KEY (user_id, backend_origin, recording_id, speaker_id),
            FOREIGN KEY (user_id, backend_origin)
                REFERENCES cloud_snapshots(user_id, backend_origin)
                ON DELETE CASCADE
        );
        """)
        try execute(db, """
        CREATE VIRTUAL TABLE IF NOT EXISTS cloud_search_fts USING fts5(
            user_id UNINDEXED,
            backend_origin UNINDEXED,
            recording_id UNINDEXED,
            row_id UNINDEXED,
            source UNINDEXED,
            section,
            title,
            speaker,
            marker,
            body,
            tokenize='unicode61'
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
        for table in ["cloud_search_fts", "cloud_speaker_overrides", "cloud_transcription_jobs", "cloud_transcripts", "cloud_recordings", "cloud_snapshots"] {
            try run(db, "DELETE FROM \(table) WHERE user_id = ? AND backend_origin = ?") { statement in
                try bindText(statement, 1, userId)
                try bindText(statement, 2, backendOrigin)
            }
        }
    }

    func insertSpeakerOverrides(_ db: OpaquePointer, _ snapshot: CloudLibrarySnapshot) throws {
        let statement = try prepare(db, """
        INSERT INTO cloud_speaker_overrides (
            user_id, backend_origin, recording_id, speaker_id, payload
        ) VALUES (?, ?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(statement) }

        for recordingID in snapshot.decodedSpeakerOverridesByRecordingID.keys.sorted() {
            guard let overrides = snapshot.decodedSpeakerOverridesByRecordingID[recordingID] else { continue }
            for speakerID in overrides.keys.sorted() {
                guard let override = overrides[speakerID] else { continue }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bindText(statement, 1, snapshot.userId)
                try bindText(statement, 2, snapshot.backendOrigin)
                try bindText(statement, 3, recordingID)
                try bindText(statement, 4, speakerID)
                try bindData(statement, 5, JSONEncoder.cloudCache.encode(override))
                try stepDone(statement, db)
            }
        }
    }

    func rebuildSearchIndex(_ db: OpaquePointer, _ snapshot: CloudLibrarySnapshot) throws {
        let recordingsByID = Dictionary(uniqueKeysWithValues: snapshot.decodedRecordings.map { ($0.id, $0) })
        let statement = try prepare(db, """
        INSERT INTO cloud_search_fts (
            user_id, backend_origin, recording_id, row_id, source,
            section, title, speaker, marker, body
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(statement) }

        for recordingID in snapshot.transcripts.keys.sorted() {
            guard let recording = recordingsByID[recordingID],
                  let transcript = snapshot.transcripts[recordingID]?.transcript else { continue }
            for entry in CloudSearchIndexBuilder.entries(recording: recording, transcript: transcript) {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bindText(statement, 1, snapshot.userId)
                try bindText(statement, 2, snapshot.backendOrigin)
                try bindText(statement, 3, entry.recordingID)
                try bindText(statement, 4, entry.targetSegmentID ?? entry.id)
                try bindText(statement, 5, entry.source.rawValue)
                try bindText(statement, 6, entry.sectionBreadcrumb)
                try bindText(statement, 7, entry.recordingTitle)
                try bindText(statement, 8, entry.speakerRawName)
                try bindText(statement, 9, entry.marker)
                try bindText(statement, 10, entry.text)
                try stepDone(statement, db)
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

    func loadSpeakerOverrides(
        _ db: OpaquePointer,
        userId: String,
        backendOrigin: String
    ) throws -> [String: [String: CloudSpeakerDisplayOverride]] {
        let statement = try prepare(db, """
        SELECT recording_id, speaker_id, payload
        FROM cloud_speaker_overrides
        WHERE user_id = ? AND backend_origin = ?
        ORDER BY recording_id ASC, speaker_id ASC
        """)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, userId)
        try bindText(statement, 2, backendOrigin)

        var overrides: [String: [String: CloudSpeakerDisplayOverride]] = [:]
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw SQLiteCacheError(sqliteMessage(db)) }
            guard let recordingID = columnText(statement, 0),
                  let speakerID = columnText(statement, 1),
                  let data = columnData(statement, 2) else { continue }
            overrides[recordingID, default: [:]][speakerID] = try JSONDecoder.cloudCache.decode(
                CloudSpeakerDisplayOverride.self,
                from: data
            )
        }
        return overrides
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

    func searchSQLiteIndex(
        _ db: OpaquePointer,
        userId: String,
        backendOrigin: String,
        query: String,
        speakerRawName: String?,
        limit: Int
    ) throws -> [CloudIndexedSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSpeaker = speakerRawName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSpeakerFilter = trimmedSpeaker?.isEmpty == false

        var clauses = [
            "user_id = ?",
            "backend_origin = ?",
        ]
        var ftsQuery: String?
        if let builtQuery = Self.ftsQuery(for: trimmedQuery) {
            ftsQuery = builtQuery
            clauses.append("cloud_search_fts MATCH ?")
        }
        if hasSpeakerFilter {
            clauses.append("speaker = ?")
        }

        let orderBy = ftsQuery == nil ? "title COLLATE NOCASE, rowid" : "rank"
        let statement = try prepare(db, """
        SELECT recording_id, row_id, source, section, title, speaker, marker, body
        FROM cloud_search_fts
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY \(orderBy)
        LIMIT ?
        """)
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        try bindText(statement, bindIndex, userId)
        bindIndex += 1
        try bindText(statement, bindIndex, backendOrigin)
        bindIndex += 1
        if let ftsQuery {
            try bindText(statement, bindIndex, ftsQuery)
            bindIndex += 1
        }
        if hasSpeakerFilter {
            try bindText(statement, bindIndex, trimmedSpeaker)
            bindIndex += 1
        }
        try bindInt(statement, bindIndex, max(1, limit))

        var results: [CloudIndexedSearchResult] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw SQLiteCacheError(sqliteMessage(db)) }
            guard let recordingID = columnText(statement, 0),
                  let rowID = columnText(statement, 1),
                  let rawSource = columnText(statement, 2),
                  let source = CloudIndexedSearchSource(rawValue: rawSource),
                  let section = columnText(statement, 3),
                  let title = columnText(statement, 4),
                  let text = columnText(statement, 7) else { continue }
            results.append(CloudIndexedSearchResult(
                id: "\(recordingID)-\(rawSource)-\(rowID)",
                recordingID: recordingID,
                recordingTitle: title,
                source: source,
                sectionBreadcrumb: section,
                marker: columnText(statement, 6),
                text: text,
                speakerRawName: columnText(statement, 5),
                targetSegmentID: source == .transcript ? rowID : nil
            ))
        }
        return results
    }

    nonisolated static func ftsQuery(for query: String) -> String? {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
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


extension JSONEncoder {
    static var cloudCache: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var cloudCache: JSONDecoder {
        JSONDecoder()
    }
}
