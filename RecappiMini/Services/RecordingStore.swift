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

    static func uploadAudioFileURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("upload.wav")
    }

    static func transcriptFileURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("transcript.md")
    }

    static func remoteManifestURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("remote-session.json")
    }

    static func sessionMetadataURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("session-metadata.json")
    }

    static func saveTranscript(_ text: String, in sessionDir: URL) throws {
        let url = transcriptFileURL(in: sessionDir)
        let content = "# Transcript\n\n\(text)\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    static func saveRemoteManifest(_ manifest: RemoteSessionManifest, in sessionDir: URL) -> RemoteSessionManifest {
        var next = manifest
        next.updatedAt = ISO8601DateFormatter().string(from: Date())
        let url = remoteManifestURL(in: sessionDir)
        if let data = try? JSONEncoder().encode(next) {
            try? data.write(to: url)
        }
        return next
    }

    static func loadRemoteManifest(in sessionDir: URL) -> RemoteSessionManifest? {
        let url = remoteManifestURL(in: sessionDir)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RemoteSessionManifest.self, from: data)
    }

    static func saveSessionMetadata(_ metadata: RecordingSessionMetadata, in sessionDir: URL) {
        let url = sessionMetadataURL(in: sessionDir)
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: url)
        }
    }

    static func loadSessionMetadata(in sessionDir: URL) -> RecordingSessionMetadata? {
        let url = sessionMetadataURL(in: sessionDir)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordingSessionMetadata.self, from: data)
    }
}
