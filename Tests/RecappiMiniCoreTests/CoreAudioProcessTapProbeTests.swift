import XCTest
@testable import RecappiMini

final class CoreAudioProcessTapProbeTests: XCTestCase {
    func testCoreAudioTapCapturesSystemPlaybackWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RECAPPI_RUN_CORE_AUDIO_TAP_PROBE"] == "1" else {
            throw XCTSkip("Set RECAPPI_RUN_CORE_AUDIO_TAP_PROBE=1 to run the local CoreAudio process tap probe.")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recappi-core-audio-tap-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let finalURL = root.appendingPathComponent("system.caf")
        let writer = SegmentedAudioWriter(
            finalURL: finalURL,
            processingQueue: DispatchQueue(label: "RecappiMini.CoreAudioTapProbe.writer")
        )
        let output = SystemAudioOutput(writer: writer)
        output.setMeteringEnabled(false)

        let capture = CoreAudioProcessTapCapture(
            selectedBundleID: nil,
            selfBundleID: "com.recappi.mini.tests",
            output: output,
            captureQueue: DispatchQueue(label: "RecappiMini.CoreAudioTapProbe.capture")
        )

        try capture.start()
        let playback = Process()
        playback.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        playback.arguments = [AutomationPaths.recordingFixture.path]
        try playback.run()
        playback.waitUntilExit()
        capture.stop()

        let capturedURL = try await writer.finishWriting()
        let url = try XCTUnwrap(capturedURL)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        XCTAssertGreaterThan(size?.intValue ?? 0, 8_000)
    }
}
