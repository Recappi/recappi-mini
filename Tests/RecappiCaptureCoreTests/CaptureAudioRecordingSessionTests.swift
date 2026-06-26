import XCTest
@testable import RecappiCaptureCore

final class CaptureAudioRecordingSessionTests: XCTestCase {
    func testStartRejectsEmptyInputSelection() async {
        let session = CaptureAudioRecordingSession(configuration: CaptureAudioRecordingSessionConfiguration(
            sessionID: "session-empty",
            sessionDirectoryURL: URL(fileURLWithPath: "/tmp/session-empty"),
            includeSystemAudio: false,
            includeMicrophone: false,
            metadata: CaptureSessionMetadata(sessionID: "session-empty")
        ))

        do {
            try await session.start()
            XCTFail("Expected start to reject an empty input selection")
        } catch let error as CaptureAudioRecordingSessionError {
            XCTAssertEqual(error, .noAudioInputs)
        } catch {
            XCTFail("Expected CaptureAudioRecordingSessionError.noAudioInputs, got \(error)")
        }
    }

    func testPauseAndResumeRemainUnsupported() async {
        let session = CaptureAudioRecordingSession(configuration: CaptureAudioRecordingSessionConfiguration(
            sessionID: "session-pause",
            sessionDirectoryURL: URL(fileURLWithPath: "/tmp/session-pause"),
            includeSystemAudio: true,
            includeMicrophone: false,
            metadata: CaptureSessionMetadata(sessionID: "session-pause")
        ))

        do {
            try await session.pause()
            XCTFail("Expected pause to be unsupported")
        } catch let error as CaptureAudioRecordingSessionError {
            XCTAssertEqual(error, .pauseUnsupported)
        } catch {
            XCTFail("Expected CaptureAudioRecordingSessionError.pauseUnsupported, got \(error)")
        }

        do {
            try await session.resume()
            XCTFail("Expected resume to be unsupported")
        } catch let error as CaptureAudioRecordingSessionError {
            XCTAssertEqual(error, .pauseUnsupported)
        } catch {
            XCTFail("Expected CaptureAudioRecordingSessionError.pauseUnsupported, got \(error)")
        }
    }

    func testConfigurationBuildsSystemEffectiveSelection() {
        let config = CaptureAudioRecordingSessionConfiguration(
            sessionID: "session-1",
            sessionDirectoryURL: URL(fileURLWithPath: "/tmp/session-1"),
            includeSystemAudio: true,
            includeMicrophone: false,
            metadata: CaptureSessionMetadata(sessionID: "session-1")
        )

        XCTAssertEqual(config.effectiveSelection, CaptureSelection(
            sourceID: "system",
            includeMicrophone: false
        ))
    }

    func testConfigurationBuildsAppEffectiveSelectionWithMicrophone() {
        let config = CaptureAudioRecordingSessionConfiguration(
            sessionID: "session-2",
            sessionDirectoryURL: URL(fileURLWithPath: "/tmp/session-2"),
            includeSystemAudio: true,
            targetBundleID: "company.thebrowser.Browser",
            includeMicrophone: true,
            microphoneDeviceID: "mic-1",
            metadata: CaptureSessionMetadata(sessionID: "session-2")
        )

        XCTAssertEqual(config.effectiveSelection, CaptureSelection(
            sourceID: "app:company.thebrowser.Browser",
            includeMicrophone: true,
            microphoneDeviceID: "mic-1"
        ))
    }

    func testConfigurationEqualityIgnoresSampleBufferTapIdentity() {
        let metadata = CaptureSessionMetadata(sessionID: "session-3")
        let lhs = CaptureAudioRecordingSessionConfiguration(
            sessionID: "session-3",
            sessionDirectoryURL: URL(fileURLWithPath: "/tmp/session-3"),
            includeSystemAudio: true,
            includeMicrophone: false,
            metadata: metadata,
            sampleBufferTap: { _, _ in }
        )
        let rhs = CaptureAudioRecordingSessionConfiguration(
            sessionID: "session-3",
            sessionDirectoryURL: URL(fileURLWithPath: "/tmp/session-3"),
            includeSystemAudio: true,
            includeMicrophone: false,
            metadata: metadata,
            sampleBufferTap: nil
        )

        XCTAssertEqual(lhs, rhs)
    }
}
