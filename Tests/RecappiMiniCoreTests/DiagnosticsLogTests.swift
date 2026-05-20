import Foundation
import XCTest
@testable import RecappiMini

final class DiagnosticsLogTests: XCTestCase {
    func testDiagnosticsFileWriterKeepsMultipleRotatedLogs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecappiDiagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = DiagnosticsFileWriter(
            fileName: "diagnostics.log",
            directory: directory,
            maxBytes: 90,
            maxRotatedFiles: 3
        )

        for index in 0..<10 {
            writer.append("level=info category=test message=\(index) \(String(repeating: "x", count: 48))")
        }
        writer.flush()

        let current = directory.appendingPathComponent("diagnostics.log")
        let first = directory.appendingPathComponent("diagnostics.1.log")
        let second = directory.appendingPathComponent("diagnostics.2.log")
        let third = directory.appendingPathComponent("diagnostics.3.log")
        let fourth = directory.appendingPathComponent("diagnostics.4.log")

        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: third.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fourth.path))
    }

    func testDiagnosticsLogExposesUserVisibleLogFolder() {
        XCTAssertEqual(
            DiagnosticsLog.logsDirectoryURL,
            DiagnosticsLog.fileURL.deletingLastPathComponent()
        )
        XCTAssertTrue(DiagnosticsLog.fileURL.lastPathComponent.hasPrefix("diagnostics"))
    }

    func testDiagnosticsLogArchiveIncludesCurrentAndRotatedLogs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecappiDiagnosticsArchive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let current = directory.appendingPathComponent("diagnostics.log")
        let rotated = directory.appendingPathComponent("diagnostics.1.log")
        try "current".write(to: current, atomically: true, encoding: .utf8)
        try "rotated".write(to: rotated, atomically: true, encoding: .utf8)

        let archive = try DiagnosticsLogArchive.create(
            logsDirectory: directory,
            currentLogURL: current,
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(archive.lastPathComponent, "RecappiMiniLogs-19700101-000000.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertGreaterThan(
            ((try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.intValue ?? 0),
            0
        )
    }
}
