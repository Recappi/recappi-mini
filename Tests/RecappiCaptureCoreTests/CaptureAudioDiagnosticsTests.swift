import Foundation
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

        try CaptureAudioDiagnostics.write(
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
}
