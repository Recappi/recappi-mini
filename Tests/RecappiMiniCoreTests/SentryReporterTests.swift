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
            from: "process.failed dir=2026-05-21_120000 recording=rec_123 file=recording.m4a domain=NSURLErrorDomain code=-1001 sessionId=session_123 generation=42 sinceOpenMs=825 cause=receive.throw closeCode=0 prompt='raw prompt' text='hello' summary='private' systemBuffers=42 systemLastAgo=0.04s"
        )

        XCTAssertEqual(fields["dir"], "2026-05-21_120000")
        XCTAssertEqual(fields["recording"], "rec_123")
        XCTAssertEqual(fields["file"], "recording.m4a")
        XCTAssertEqual(fields["domain"], "NSURLErrorDomain")
        XCTAssertEqual(fields["code"], "-1001")
        XCTAssertEqual(fields["sessionId"], "session_123")
        XCTAssertEqual(fields["generation"], "42")
        XCTAssertEqual(fields["sinceOpenMs"], "825")
        XCTAssertEqual(fields["cause"], "receive.throw")
        XCTAssertEqual(fields["closeCode"], "0")
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

    func testSentrySampleRateNormalizationClampsOverrides() {
        XCTAssertEqual(SentryReporter.normalizedSampleRate(nil, default: 0.05), 0.05)
        XCTAssertEqual(SentryReporter.normalizedSampleRate("0.1", default: 0.05), 0.1)
        XCTAssertEqual(SentryReporter.normalizedSampleRate(" 1.7 ", default: 0.05), 1.0)
        XCTAssertEqual(SentryReporter.normalizedSampleRate("-0.2", default: 0.05), 0.0)
        XCTAssertEqual(SentryReporter.normalizedSampleRate("nope", default: 0.05), 0.05)
    }

    func testNativeSigtermReportingDefaultsOffUnlessExplicitlyEnabled() {
        XCTAssertFalse(SentryReporter.nativeSigtermReportingEnabled(nil))
        XCTAssertFalse(SentryReporter.nativeSigtermReportingEnabled(""))
        XCTAssertFalse(SentryReporter.nativeSigtermReportingEnabled("true"))
        XCTAssertFalse(SentryReporter.nativeSigtermReportingEnabled("0"))
        XCTAssertTrue(SentryReporter.nativeSigtermReportingEnabled("1"))
        XCTAssertTrue(SentryReporter.nativeSigtermReportingEnabled(" 1 "))
    }

    func testNetworkRequestFingerprintsUsePathAndStatus() {
        let transcript404 = SentryReporter.diagnosticFingerprint(
            level: "error",
            category: "network",
            message: "request.failed attempts=1 method=GET path=/api/recordings/a810dd36-974d-419d-8415-aec679fb215f/transcript domain=RecappiMini.RecappiAPIError code=0 message=Recappi API error (status 404): Transcript not found"
        )
        let anotherTranscript404 = SentryReporter.diagnosticFingerprint(
            level: "error",
            category: "network",
            message: "request.failed attempts=1 method=GET path=/api/recordings/b720ee47-1234-4aa8-9455-9765c66f08ac/transcript domain=RecappiMini.RecappiAPIError code=0 message=Recappi API error (status 404): Transcript not found"
        )
        let realtime429 = SentryReporter.diagnosticFingerprint(
            level: "error",
            category: "network",
            message: "request.failed attempts=1 method=POST path=/api/openai/realtime/sessions domain=RecappiMini.RecappiAPIError code=0 message=Recappi API error (status 429): OpenAI Realtime session claim rate exceeded (10/minute)."
        )

        XCTAssertEqual(
            transcript404,
            [
                "recappi",
                "network",
                "request.failed",
                "method:GET",
                "path:/api/recordings/:id/transcript",
                "status:404",
                "domain:RecappiMini.RecappiAPIError",
                "code:0",
            ]
        )
        XCTAssertEqual(transcript404, anotherTranscript404)
        XCTAssertNotEqual(transcript404, realtime429)
        XCTAssertTrue(realtime429.contains("path:/api/openai/realtime/sessions"))
        XCTAssertTrue(realtime429.contains("status:429"))
    }

    func testCancelledNetworkRequestsDoNotCaptureSentryErrors() {
        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "network",
                message: "request.failed attempts=1 method=GET path=/api/recordings domain=NSURLErrorDomain code=-999 message=cancelled"
            )
        )

        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "network",
                message: "request.failed attempts=3 method=PUT path=/api/recordings/rec_123/parts/1 domain=NSURLErrorDomain code=-1200 message=A TLS error caused the secure connection to fail."
            )
        )

        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "processing",
                message: "upload.failed file=recording.m4a recording=rec_123 domain=NSURLErrorDomain code=-1009 message=The Internet connection appears to be offline."
            )
        )

        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "live-caption",
                message: "ws.failed mode=translation:zh sessionId=mock generation=1 sinceOpenMs=1913 cause=receive.throw closeCode=1005 domain=NSPOSIXErrorDomain code=57 message=Socket is not connected"
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

    func testRealtimeClaimRateLimitDoesNotCaptureSentryErrors() {
        let errorSummary = "domain=RecappiMini.RecappiAPIError code=0 message=Recappi API error (status 429): OpenAI Realtime session claim rate exceeded (10/minute)."

        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "network",
                message: "request.failed attempts=1 method=POST path=/api/openai/realtime/sessions \(errorSummary)"
            )
        )

        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "live-caption",
                message: "claim.failed mode=translation:zh attempt=4 \(errorSummary)"
            )
        )

        XCTAssertTrue(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "network",
                message: "request.failed attempts=1 method=POST path=/api/recordings \(errorSummary)"
            )
        )

        XCTAssertTrue(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "live-caption",
                message: "ws.failed mode=translation:zh sessionId=mock-session generation=200 sinceOpenMs=825 cause=receive.throw closeCode=0 domain=NSURLErrorDomain code=-1011 message=There was a bad response from the server."
            ),
            "The user-visible WebSocket failure must stay as the captured error while the follow-up 429 is suppressed."
        )
    }

    func testLocalOnlyRecordingDelete404DoesNotCaptureSentryErrors() {
        let errorSummary = "domain=RecappiMini.RecappiAPIError code=0 message=Recappi API error (status 404): Recording not found"

        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "network",
                message: "request.failed attempts=1 method=DELETE path=/api/recordings/local-2026-05-10_175443 \(errorSummary)"
            )
        )

        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "cloud",
                message: "recording.delete.failed recordingID=local-2026-05-10_175443 \(errorSummary)"
            )
        )

        XCTAssertTrue(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "network",
                message: "request.failed attempts=1 method=DELETE path=/api/recordings/rec_123 \(errorSummary)"
            )
        )
    }

    func testRecordingUploadLayerNoiseKeepsOnlyCanonicalUploadFailure() {
        let errorSummary = "domain=RecappiMini.RecappiAPIError code=0 message=Recappi API error (status 500): upstream down"

        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "network",
                message: "request.failed attempts=3 method=PUT path=/api/recordings/e0095f22-edb6-4375-9c5b-0055eaba1586/parts/1 \(errorSummary)"
            )
        )

        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "processing",
                message: "upload.attempt.failed recording=e0095f22-edb6-4375-9c5b-0055eaba1586 \(errorSummary)"
            )
        )

        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "recording-panel",
                message: "process_session.failed visible=true \(errorSummary)"
            )
        )

        XCTAssertTrue(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "processing",
                message: "upload.failed file=recording.m4a recording=e0095f22-edb6-4375-9c5b-0055eaba1586 \(errorSummary)"
            )
        )

        XCTAssertTrue(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "network",
                message: "request.failed attempts=3 method=GET path=/api/recordings \(errorSummary)"
            )
        )
    }

    func testTransientLiveCaptionSocketDisconnectDoesNotCaptureSentryErrors() {
        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "live-caption",
                message: "ws.failed mode=translation:zh sessionId=e6e87f05-fdb0-4479-8af5-197ba0d25549 generation=1 sinceOpenMs=1913 cause=receive.throw closeCode=1005 domain=NSPOSIXErrorDomain code=57 message=The operation couldn't be completed. Socket is not connected"
            )
        )

        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "live-caption",
                message: "ws.failed mode=transcription sessionId=e6e87f05-fdb0-4479-8af5-197ba0d25549 generation=6 sinceOpenMs=474000 cause=receive.throw closeCode=1005 domain=NSPOSIXErrorDomain code=54 message=Connection reset by peer"
            )
        )

        XCTAssertFalse(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "live-caption",
                message: "ws.failed mode=translation:zh sessionId=65d8411f-2df4-4aad-a7d4-5e79cdb06aba generation=1 sinceOpenMs=4171 cause=receive.throw closeCode=0 domain=NSURLErrorDomain code=-1200 message=A TLS error caused the secure connection to fail."
            )
        )

        XCTAssertTrue(
            SentryReporter.shouldCaptureDiagnosticError(
                level: "error",
                category: "live-caption",
                message: "ws.failed mode=translation:zh sessionId=mock-session generation=200 sinceOpenMs=825 cause=receive.throw closeCode=1005 domain=NSURLErrorDomain code=-1011 message=There was a bad response from the server."
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

    func testAppHangTrackingPauseGateReferenceCountsModalAlerts() {
        var gate = AppHangTrackingPauseGate()

        XCTAssertFalse(gate.isPaused)
        XCTAssertTrue(gate.pause())
        XCTAssertTrue(gate.isPaused)
        XCTAssertFalse(gate.pause())
        XCTAssertTrue(gate.isPaused)
        XCTAssertFalse(gate.resume())
        XCTAssertTrue(gate.isPaused)
        XCTAssertTrue(gate.resume())
        XCTAssertFalse(gate.isPaused)
        XCTAssertFalse(gate.resume())
        XCTAssertFalse(gate.isPaused)
    }

    @MainActor
    func testAppUpdaterUserDriverDelegateForwardsSparkleModalCallbacks() {
        let delegate = AppUpdaterUserDriverDelegate()
        var events: [String] = []

        delegate.onWillShowModalAlert = { events.append("pause") }
        delegate.onDidShowModalAlert = { events.append("resume") }
        delegate.onWillFinishUpdateSession = { events.append("finish") }

        delegate.standardUserDriverWillShowModalAlert()
        delegate.standardUserDriverDidShowModalAlert()
        delegate.standardUserDriverWillFinishUpdateSession()

        XCTAssertEqual(events, ["pause", "resume", "finish"])
    }
}
