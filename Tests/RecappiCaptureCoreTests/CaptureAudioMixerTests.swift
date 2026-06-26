import Foundation
import XCTest
@testable import RecappiCaptureCore

final class CaptureAudioMixerTests: XCTestCase {
    func testReportsNoCapturedAudioForEmptySourceList() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        do {
            try await CaptureAudioMixer.mix(sources: [], to: destination)
            XCTFail("Expected an empty source list to fail.")
        } catch CaptureAudioError.noCapturedAudio {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        } catch {
            XCTFail("Expected CaptureAudioError.noCapturedAudio, got \(error).")
        }
    }

    func testReportsUnreadableSource() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let invalidSource = temp.appendingPathComponent("mic.m4a")
        try Data("not an audio file".utf8).write(to: invalidSource)
        let destination = temp.appendingPathComponent("mixed-recording.m4a")

        do {
            try await CaptureAudioMixer.mix(sources: [invalidSource], to: destination)
            XCTFail("Expected an unreadable source to fail.")
        } catch CaptureAudioError.sourceUnreadable(let fileName, let reason) {
            XCTAssertEqual(fileName, "mic.m4a")
            XCTAssertFalse(reason.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        } catch {
            XCTFail("Expected CaptureAudioError.sourceUnreadable, got \(error).")
        }
    }

    func testOutputHeadroomAveragesMultipleSources() {
        XCTAssertEqual(CaptureAudioMixer.outputHeadroom(forSourceCount: 1), 1.0)
        XCTAssertEqual(CaptureAudioMixer.outputHeadroom(forSourceCount: 2), 0.5)
        XCTAssertEqual(CaptureAudioMixer.outputHeadroom(forSourceCount: 3), 0.5)
    }
}
