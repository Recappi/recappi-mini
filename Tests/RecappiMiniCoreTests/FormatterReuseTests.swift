import XCTest
@testable import RecappiMini

/// Proves that hoisting the per-call `DateFormatter` / `ISO8601DateFormatter`
/// instances in `RecordingStore` and `SessionProcessor` to reused statics keeps
/// observable output byte-identical and parsing behavior unchanged. The
/// formatters themselves are `private`, so equivalence is asserted at the public
/// boundaries that consume them.
final class FormatterReuseTests: XCTestCase {
    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `saveRemoteManifest` stamps `updatedAt` via the reused
    /// `ISO8601DateFormatter`. The persisted string must remain a valid
    /// internet-date-time value that a freshly allocated reference formatter
    /// (the previous per-call behavior) can parse back.
    func testSavedManifestTimestampMatchesReferenceISO8601Format() throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let before = Date()
        let saved = RecordingStore.saveRemoteManifest(.stage("verifyingSession"), in: temp)
        let after = Date()

        let reference = ISO8601DateFormatter()
        let parsed = try XCTUnwrap(
            reference.date(from: saved.updatedAt),
            "Hoisted ISO8601 formatter must emit a string the reference formatter parses"
        )
        // ISO8601 default options drop sub-second precision; allow the parsed
        // value to land anywhere within the save window (rounded to seconds).
        XCTAssertGreaterThanOrEqual(parsed.timeIntervalSince1970, before.timeIntervalSince1970 - 1)
        XCTAssertLessThanOrEqual(parsed.timeIntervalSince1970, after.timeIntervalSince1970 + 1)

        // Round-trip back through the reference formatter: re-formatting the
        // parsed date reproduces the persisted string exactly.
        XCTAssertEqual(reference.string(from: parsed), saved.updatedAt)
    }

    /// `localRecordingCreatedAt` parses `metadata.startedAt` with the reused
    /// `ISO8601DateFormatter`. The parsed `createdAt` exposed on the local
    /// placeholder must equal the reference formatter's parse of the same input.
    func testLocalPlaceholderParsesStartedAtIdenticallyToReference() throws {
        let temp = try makeTemporaryDirectory()
        let session = temp.appendingPathComponent("2026-05-25_111500", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try Data(repeating: 9, count: 64).write(to: RecordingStore.audioFileURL(in: session))

        let startedAt = "2026-05-25T11:15:00Z"
        var metadata = RecordingSessionMetadata.capture(
            sourceTitle: "Design sync",
            sourceAppName: "Google Meet",
            sourceBundleID: "com.google.Chrome"
        )
        metadata.startedAt = startedAt
        RecordingStore.saveSessionMetadata(metadata, in: session)

        let recording = try XCTUnwrap(SessionProcessor.localRecordingPlaceholder(
            sessionDir: session,
            duration: 30,
            status: .ready
        ))

        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: startedAt))
        XCTAssertEqual(try XCTUnwrap(recording.createdAt), referenceDate)
    }

    /// Session directory names are written with one formatter
    /// (`createSessionDirectory`, no locale) and parsed back with another
    /// (`sessionDirectoryDate`, `en_US_POSIX`). Both share `yyyy-MM-dd_HHmmss`.
    /// When `startedAt` is unparseable, `localRecordingCreatedAt` falls back to
    /// parsing the directory name; that parse must match a reference POSIX
    /// formatter, proving the write/read formats stay mutually compatible after
    /// hoisting.
    func testDirectoryNameDateParsesIdenticallyToReferenceWhenStartedAtMissing() throws {
        let temp = try makeTemporaryDirectory()
        let name = "2026-05-25_111500"
        let session = temp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try Data(repeating: 9, count: 64).write(to: RecordingStore.audioFileURL(in: session))

        // Empty startedAt forces the directory-name fallback path.
        var metadata = RecordingSessionMetadata.capture(
            sourceTitle: "Design sync",
            sourceAppName: nil,
            sourceBundleID: nil
        )
        metadata.startedAt = ""
        RecordingStore.saveSessionMetadata(metadata, in: session)

        let recording = try XCTUnwrap(SessionProcessor.localRecordingPlaceholder(
            sessionDir: session,
            duration: 30,
            status: .ready
        ))

        let reference = DateFormatter()
        reference.locale = Locale(identifier: "en_US_POSIX")
        reference.dateFormat = "yyyy-MM-dd_HHmmss"
        let referenceDate = try XCTUnwrap(reference.date(from: name))
        XCTAssertEqual(try XCTUnwrap(recording.createdAt), referenceDate)
    }
}
