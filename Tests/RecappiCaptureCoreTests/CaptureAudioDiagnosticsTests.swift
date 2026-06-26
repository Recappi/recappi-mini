import Foundation
import AVFoundation
import XCTest
@testable import RecappiCaptureCore

final class CaptureAudioDiagnosticsTests: XCTestCase {
    func testWritesCaptureHealthAndByteCounts() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let source = temp.appendingPathComponent("system.m4a")
        try Data([1, 2, 3]).write(to: source)
        let health = [
            CaptureAudioHealth(
                source: "system",
                bufferCount: 12,
                includedBufferCount: 12,
                firstBufferUptime: 100,
                lastBufferUptime: 104,
                secondsSinceLastBuffer: 0.25,
                meterFrameCount: 3,
                averagePeak: 0.2,
                maxPeak: 0.6
            ),
        ]

        let returnedDiagnostics = try CaptureAudioDiagnostics.write(
            sources: [source],
            output: nil,
            to: temp,
            captureHealth: health
        )

        let diagnosticsURL = temp.appendingPathComponent("audio-capture.json")
        let data = try Data(contentsOf: diagnosticsURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let diagnostics = try decoder.decode(CaptureAudioDiagnostics.self, from: data)

        XCTAssertEqual(diagnostics.sources.first?.role, "system")
        XCTAssertEqual(diagnostics.sources.first?.byteCount, 3)
        XCTAssertEqual(diagnostics.captureHealth, health)
        XCTAssertEqual(returnedDiagnostics.sources.first?.byteCount, 3)
    }

    func testInfersSourceRolesFromFileNames() {
        let temp = FileManager.default.temporaryDirectory
        let diagnostics = CaptureAudioDiagnostics(
            createdAt: Date(timeIntervalSince1970: 0),
            sources: [
                temp.appendingPathComponent("system.caf"),
                temp.appendingPathComponent("mic.caf"),
                temp.appendingPathComponent("other.caf"),
            ],
            output: temp.appendingPathComponent("recording.m4a")
        )

        XCTAssertEqual(diagnostics.sources.map(\.role), ["system", "mic", "source"])
        XCTAssertEqual(diagnostics.output?.role, "mixed")
    }

    func testExposesArtifactDiagnosticsSummary() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let source = temp.appendingPathComponent("system.caf")
        let output = temp.appendingPathComponent("recording.m4a")
        try Data([1, 2, 3]).write(to: source)
        try Data([4, 5, 6, 7]).write(to: output)

        let diagnostics = CaptureAudioDiagnostics(sources: [source], output: output)

        XCTAssertNil(diagnostics.artifactDurationMs)
        XCTAssertEqual(diagnostics.artifactDiagnostics["source.count"], "1")
        XCTAssertEqual(diagnostics.artifactDiagnostics["system.byteCount"], "3")
        XCTAssertEqual(diagnostics.artifactDiagnostics["mixed.byteCount"], "4")
        XCTAssertEqual(diagnostics.artifactDiagnostics["mixed.fileName"], "recording.m4a")
    }

    func testExposesArtifactDurationFromMixedOutput() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let output = temp.appendingPathComponent("recording.m4a")
        try Self.writeSilentAudio(to: output, durationSeconds: 1.0)

        let diagnostics = CaptureAudioDiagnostics(sources: [], output: output)

        let durationMs = try XCTUnwrap(diagnostics.artifactDurationMs)
        XCTAssertEqual(durationMs, 1_000, accuracy: 20)
        XCTAssertEqual(diagnostics.artifactDiagnostics["mixed.durationSeconds"], "1.000")
        XCTAssertEqual(diagnostics.artifactDiagnostics["mixed.channelCount"], "1")
    }

    private static func writeSilentAudio(to url: URL, durationSeconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames = AVAudioFrameCount(format.sampleRate * durationSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
