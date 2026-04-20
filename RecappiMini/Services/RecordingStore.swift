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

    static func summaryFileURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("summary.md")
    }

    static func actionItemsFileURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("action-items.md")
    }

    static func remoteManifestURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("remote-session.json")
    }

    static func saveTranscript(_ text: String, in sessionDir: URL) throws {
        let url = transcriptFileURL(in: sessionDir)
        let content = "# Transcript\n\n\(text)\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes the summary plus inline "Key Decisions" section (if any) to
    /// summary.md. Decisions aren't interesting enough to merit their own
    /// file but they're part of the summary story.
    static func saveSummary(_ insights: MeetingInsights, in sessionDir: URL) throws {
        guard !insights.summary.isEmpty || !insights.keyDecisions.isEmpty else { return }
        var content = "# Meeting Summary\n\n"
        if !insights.summary.isEmpty {
            content += insights.summary
            if !content.hasSuffix("\n") { content += "\n" }
        }
        if !insights.keyDecisions.isEmpty {
            content += "\n## Key Decisions\n\n"
            for decision in insights.keyDecisions {
                content += "- \(decision)\n"
            }
        }
        try content.write(to: summaryFileURL(in: sessionDir), atomically: true, encoding: .utf8)
    }

    /// Writes a GitHub-style task list so users can tick items off in any
    /// markdown editor. Skips writing when the list is empty.
    static func saveActionItems(_ items: [MeetingInsights.ActionItem], in sessionDir: URL) throws {
        guard !items.isEmpty else { return }
        var content = "# Action Items\n\n"
        for item in items {
            var line = "- [ ] "
            if let owner = item.owner, !owner.isEmpty {
                line += "**\(owner)** — "
            }
            line += item.text
            if let due = item.due, !due.isEmpty {
                line += " _(due: \(due))_"
            }
            content += line + "\n"
        }
        try content.write(to: actionItemsFileURL(in: sessionDir), atomically: true, encoding: .utf8)
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
}
