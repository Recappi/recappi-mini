import Foundation

struct RecordingStore {
    static let baseDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Recappi Mini", isDirectory: true)
    }()

    static func createSessionDirectory() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = formatter.string(from: Date())
        let dir = baseDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func audioFileURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("recording.m4a")
    }

    static func transcriptFileURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("transcript.md")
    }

    static func summaryFileURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("summary.md")
    }

    static func saveTranscript(_ text: String, in sessionDir: URL) throws {
        let url = transcriptFileURL(in: sessionDir)
        let content = "# Transcript\n\n\(text)\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    static func saveSummary(_ text: String, in sessionDir: URL) throws {
        let url = summaryFileURL(in: sessionDir)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
