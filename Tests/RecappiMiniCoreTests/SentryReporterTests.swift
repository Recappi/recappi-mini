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

    func testMissingTranscript404DoesNotCaptureSentryErrors() {
        let errorSummary = "domain=RecappiMini.RecappiAPIError code=0 message=Recappi API error (status 404): Transcript not found"

        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "network",
                message: "request.failed attempts=1 method=GET path=/api/recordings/rec_123/transcript \(errorSummary)"
            )
        )

        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "cloud",
                message: "transcript.load.failed recordingID=rec_123 \(errorSummary)"
            )
        )

        XCTAssertTrue(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "network",
                message: "request.failed attempts=1 method=GET path=/api/recordings domain=RecappiMini.RecappiAPIError code=0 message=Recappi API error (status 404): Recording not found"
            )
        )
    }

    func testSubscriptionRenewal503OnlySuppressesLowerLayerRetryNoise() {
        let errorSummary = "domain=RecappiMini.RecappiAPIError code=0 message=Recappi API error (status 503): Subscription is renewing — plan state is between periods. Retry in a few seconds."

        for (category, message) in [
            (
                "network",
                "request.failed attempts=5 method=POST path=/api/recordings \(errorSummary)"
            ),
            (
                "processing",
                "upload.failed file=recording.m4a recording=none \(errorSummary)"
            ),
            (
                "processing",
                "process.failed dir=2026-05-25_100318 \(errorSummary)"
            ),
        ] {
            XCTAssertFalse(
                SentryReporter.shouldCaptureDiagnosticError(
                    level: "error",
                    category: category,
                    message: message
                )
            )
        }

        for (category, message) in [
            (
                "cloud",
                "local_processing.failed recordingID=local-2026-05-25_100318 action=transcriptAndSummary \(errorSummary)"
            ),
            (
                "cloud",
                "transcription.start.failed recordingID=rec_123 action=transcriptAndSummary \(errorSummary)"
            ),
        ] {
            XCTAssertTrue(
                SentryReporter.shouldCaptureDiagnosticError(
                    level: "error",
                    category: category,
                    message: message
                )
            )
        }

        XCTAssertTrue(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "network",
                message: "request.failed attempts=5 method=POST path=/api/recordings domain=RecappiMini.RecappiAPIError code=0 message=Recappi API error (status 503): upstream down"
            )
        )
    }

    func testSentryUserUsesBackendUserIDWithoutPII() {
        let session = UserSession(
            userId: "user_123",
            email: "friend@example.com",
            name: "Friendly User",
            imageURL: nil,
            expiresAt: "2026-05-23T00:00:00Z",
            backendOrigin: "https://recordmeet.ing"
        )

        let user = SentryReporter.sentryUser(for: session)

        XCTAssertEqual(user.userId, "user_123")
        XCTAssertNil(user.email)
        XCTAssertNil(user.name)
        XCTAssertNil(user.username)
    }

    func testUserIdentityHelpersAreSafeBeforeSDKStart() {
        let session = UserSession(
            userId: "user_123",
            email: "friend@example.com",
            name: "Friendly User",
            imageURL: nil,
            expiresAt: "2026-05-23T00:00:00Z",
            backendOrigin: "https://recordmeet.ing"
        )

        SentryReporter.setUserIdentity(session)
        SentryReporter.clearUserIdentity()
    }
}
