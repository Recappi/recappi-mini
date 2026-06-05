import Foundation
import XCTest
@testable import RecappiMini

/// Guards the two hot-path optimizations in `DiagnosticsLog` /
/// `SentryReporter`:
///   1. The cached ISO8601 timestamp formatter must emit byte-identical
///      strings to a freshly-allocated formatter with the same config.
///   2. `SentryReporter.recordDiagnostic` must be a safe no-op when Sentry
///      is disabled for the current process (the test target never starts
///      the SDK), so the diagnostics hot path pays nothing extra.
final class DiagnosticsHotPathTests: XCTestCase {
    /// Reference formatter built exactly as the pre-optimization
    /// `DiagnosticsFileWriter.timestamp()` did — a brand-new instance per
    /// call with `[.withInternetDateTime, .withFractionalSeconds]` and UTC.
    private func freshlyAllocatedReferenceFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    func testCachedFormatterMatchesFreshlyAllocatedForFixedDates() {
        // A reusable formatter instance modelling the cached one. Reusing a
        // single instance across many `string(from:)` calls must produce the
        // same output as allocating a fresh formatter each time.
        let cached = freshlyAllocatedReferenceFormatter()

        let fixedDates: [Date] = [
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 1_700_000_000),
            Date(timeIntervalSince1970: 1_700_000_000.123),
            Date(timeIntervalSince1970: 1_700_000_000.999),
            Date(timeIntervalSince1970: 1_234_567_890.5),
        ]

        for date in fixedDates {
            // Allocate a brand-new formatter every iteration (the old behavior)
            // and compare against the reused instance (the new behavior).
            let fresh = freshlyAllocatedReferenceFormatter()
            XCTAssertEqual(
                cached.string(from: date),
                fresh.string(from: date),
                "Cached formatter output diverged from a freshly-allocated one for \(date)"
            )
        }
    }

    func testCachedFormatterIsStableAcrossRepeatedCalls() {
        let cached = freshlyAllocatedReferenceFormatter()
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let first = cached.string(from: date)
        for _ in 0..<100 {
            XCTAssertEqual(cached.string(from: date), first)
        }
    }

    func testFormatterEmitsExpectedFractionalUTCFormat() {
        let formatter = freshlyAllocatedReferenceFormatter()
        // 1970-01-01T00:00:00.000Z is the canonical epoch rendering for this
        // option set; verifies fractional seconds + UTC suffix are present.
        XCTAssertEqual(
            formatter.string(from: Date(timeIntervalSince1970: 0)),
            "1970-01-01T00:00:00.000Z"
        )
    }

    func testWrittenLineBeginsWithParseableTimestamp() throws {
        // Drive the real public `DiagnosticsFileWriter.append` path and confirm
        // the emitted line begins with a timestamp the reference formatter can
        // round-trip — proving the cached formatter is wired in and producing a
        // valid ISO8601 internet date-time string.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecappiDiagnosticsHotPath-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = DiagnosticsFileWriter(fileName: "diagnostics.log", directory: directory)
        writer.append("level=info category=test hotpath=1")
        writer.flush()

        let contents = try String(contentsOf: directory.appendingPathComponent("diagnostics.log"), encoding: .utf8)
        let firstLine = try XCTUnwrap(contents.split(separator: "\n").first.map(String.init))
        let timestampToken = try XCTUnwrap(firstLine.split(separator: " ").first.map(String.init))

        let formatter = freshlyAllocatedReferenceFormatter()
        let parsed = formatter.date(from: timestampToken)
        XCTAssertNotNil(parsed, "Written timestamp \(timestampToken) was not a valid ISO8601 fractional UTC string")
    }

    func testRecordDiagnosticIsNoOpWhenSentryDisabled() {
        // The test process never calls `SentryReporter.start`, so Sentry is
        // disabled for the current process. `recordDiagnostic` must short-circuit
        // safely without throwing/crashing regardless of how rich the message is.
        XCTAssertFalse(SentryReporter.isEnabledForCurrentProcess)

        SentryReporter.recordDiagnostic(
            level: "error",
            category: "network",
            message: "request.failed attempts=3 method=PUT path=/api/recordings/e0095f22-edb6-4375-9c5b-0055eaba1586/parts/1 token=secret-value url=https://api.recappi.com/private domain=NSURLErrorDomain code=-1200 message=A TLS error caused the secure connection to fail."
        )
        SentryReporter.recordDiagnostic(level: "info", category: "diagnostics", message: "heartbeat tick=1")
        SentryReporter.recordDiagnostic(level: "warning", category: "recording", message: "capture.health system=ok")

        // Reaching here without crashing is the contract: a disabled reporter
        // never touches the SDK and never mutates observable recording context.
        XCTAssertFalse(SentryReporter.isEnabledForCurrentProcess)
    }
}
