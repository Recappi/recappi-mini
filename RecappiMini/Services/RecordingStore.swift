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

    static func sessionMetadataURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("session-metadata.json")
    }

    static func saveTranscript(_ text: String, in sessionDir: URL) throws {
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try transcriptMarkdown(title: "Transcript", text: text)
            .write(to: transcriptFileURL(in: sessionDir), atomically: true, encoding: .utf8)
        try removeLegacyTranscriptionAlias(in: sessionDir)
    }

    static func saveTranscriptArtifacts(_ transcript: TranscriptResponse, in sessionDir: URL) throws {
        try saveTranscript(transcript.text, in: sessionDir)
        try writeOptionalMarkdown(summaryMarkdown(for: transcript), to: summaryFileURL(in: sessionDir))
        try writeOptionalMarkdown(actionItemsMarkdown(for: transcript), to: actionItemsFileURL(in: sessionDir))
    }

    static func loadTranscript(in sessionDir: URL) -> String? {
        let urls = [transcriptFileURL(in: sessionDir), legacyTranscriptionFileURL(in: sessionDir)]
        guard var text = urls.lazy.compactMap({ try? String(contentsOf: $0, encoding: .utf8) }).first else {
            return nil
        }
        if text.hasPrefix("# Transcript") || text.hasPrefix("# Transcription") {
            let parts = text.components(separatedBy: "\n\n")
            if parts.count > 1 {
                text = parts.dropFirst().joined(separator: "\n\n")
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    static func removeLegacyTranscriptionAlias(in sessionDir: URL) throws {
        let aliasURL = legacyTranscriptionFileURL(in: sessionDir)
        guard FileManager.default.fileExists(atPath: transcriptFileURL(in: sessionDir).path),
              FileManager.default.fileExists(atPath: aliasURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: aliasURL)
    }

    private static func transcriptMarkdown(title: String, text: String) -> String {
        "# \(title)\n\n\(text)\n"
    }

    private static func legacyTranscriptionFileURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent("transcription.md")
    }

    private static func summaryMarkdown(for transcript: TranscriptResponse) -> String? {
        var sections: [String] = []
        if let insights = transcript.summaryInsights {
            if let summary = insights.summaryText {
                sections.append("## TL;DR\n\n\(summary)")
            } else if let summary = transcript.summary {
                sections.append("## Summary\n\n\(summary)")
            }
            appendBulletSection(title: "Key Points", items: insights.keyPoints, to: &sections)
            appendBulletSection(title: "Topics", items: insights.topics, to: &sections)
            appendBulletSection(title: "Decisions", items: insights.decisions, to: &sections)
            appendBulletSection(title: "Action Items", items: insights.actionItemTexts, to: &sections)
            let quoteLines = insights.quoteTexts.map { "> \($0)" }
            appendSection(title: "Notable Quotes", lines: quoteLines, separator: "\n\n", to: &sections)
        } else if let summary = transcript.summary {
            sections.append("## Summary\n\n\(summary)")
        }
        guard !sections.isEmpty else { return nil }
        return "# Summary\n\n\(sections.joined(separator: "\n\n"))\n"
    }

    private static func actionItemsMarkdown(for transcript: TranscriptResponse) -> String? {
        guard let actionItems = transcript.actionItems, !actionItems.isEmpty else { return nil }
        return "# Action Items\n\n\(markdownList(actionItems))\n"
    }

    private static func appendBulletSection(title: String, items: [String], to sections: inout [String]) {
        appendSection(title: title, lines: items.map { "- \($0)" }, separator: "\n", to: &sections)
    }

    private static func appendSection(
        title: String,
        lines: [String],
        separator: String,
        to sections: inout [String]
    ) {
        guard !lines.isEmpty else { return }
        sections.append("## \(title)\n\n\(lines.joined(separator: separator))")
    }

    private static func markdownList(_ items: [String]) -> String {
        items.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func writeOptionalMarkdown(_ content: String?, to url: URL) throws {
        guard let content else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
