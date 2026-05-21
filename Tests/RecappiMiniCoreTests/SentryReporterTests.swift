import Foundation
import XCTest
@testable import RecappiMini

final class SentryReporterTests: XCTestCase {
    func testTelemetryMessageScrubsLocalPathsAndSecrets() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let message = """
        upload.failed path=\(home)/Documents/Recappi Mini/2026-05-21_120000/recording.m4a token=secret-value url=https://api.recappi.com/private
        """

        let sanitized = SentryReporter.sanitizedTelemetryMessage(message)

        XCTAssertFalse(sanitized.contains(home))
        XCTAssertFalse(sanitized.contains("secret-value"))
        XCTAssertFalse(sanitized.contains("api.recappi.com/private"))
        XCTAssertTrue(sanitized.contains("path=~/Documents"))
        XCTAssertTrue(sanitized.contains("token=<redacted>"))
        XCTAssertTrue(sanitized.contains("<url>"))
    }

    func testTelemetryFieldsKeepSafeDiagnosticsOnly() {
        let fields = SentryReporter.safeTelemetryFields(
            from: "process.failed dir=2026-05-21_120000 recording=rec_123 file=recording.m4a domain=NSURLErrorDomain code=-1001 prompt='raw prompt' text='hello' summary='private' systemBuffers=42 systemLastAgo=0.04s"
        )

        XCTAssertEqual(fields["dir"], "2026-05-21_120000")
        XCTAssertEqual(fields["recording"], "rec_123")
        XCTAssertEqual(fields["file"], "recording.m4a")
        XCTAssertEqual(fields["domain"], "NSURLErrorDomain")
        XCTAssertEqual(fields["code"], "-1001")
        XCTAssertEqual(fields["systemBuffers"], "42")
        XCTAssertEqual(fields["systemLastAgo"], "0.04s")
        XCTAssertNil(fields["prompt"])
        XCTAssertNil(fields["text"])
        XCTAssertNil(fields["summary"])
    }

    func testOperationNameUsesFirstDiagnosticToken() {
        XCTAssertEqual(
            SentryReporter.operationName(from: "upload.attempt.failed recording=rec_123 domain=NSURLErrorDomain"),
            "upload.attempt.failed"
        )
    }

    func testCancelledNetworkRequestsDoNotCaptureSentryErrors() {
        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "network",
                message: "request.failed attempts=1 method=GET path=/api/recordings domain=NSURLErrorDomain code=-999 message=cancelled"
            )
        )

        XCTAssertTrue(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "network",
                message: "request.failed attempts=1 method=GET path=/api/recordings domain=NSURLErrorDomain code=-1001 message=timed-out"
            )
        )
    }
}
