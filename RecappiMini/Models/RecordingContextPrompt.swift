import Foundation

enum RecordingContextPrompt {
    static func liveCaptionHint(sceneRaw: String, extraPrompt: String) -> String? {
        let scene = RecordingSceneTemplate.option(for: sceneRaw)
        let trimmed = extraPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        var lines = [
            "Context: This is a \(scene.title.lowercased()) recording.",
            "Use this context as a best-effort hint for names, product terms, and acronyms in live transcription."
        ]
        if !trimmed.isEmpty {
            lines.append("Terms and notes: \(trimmed)")
        }

        return lines.joined(separator: "\n")
    }

    static func text(sceneRaw: String, extraPrompt: String) -> String? {
        let scene = RecordingSceneTemplate.option(for: sceneRaw)
        var lines = [
            "Scene: \(scene.title).",
            "Use this context for transcript terminology and the post-processing summary structure."
        ]

        switch scene {
        case .meeting:
            lines.append("For summary, prefer sections for summary, decisions, action items, and open questions.")
        case .podcast:
            lines.append("For summary, prefer episode summary, key topics, notable moments, and follow-up ideas.")
        case .interview:
            lines.append("For summary, prefer profile, topic evidence, concerns, and follow-up questions.")
        case .casual:
            lines.append("For summary, prefer highlights and things worth remembering.")
        case .lecture:
            lines.append("For summary, prefer key concepts, examples, and review points.")
        }

        let trimmed = extraPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append("Additional context: \(trimmed)")
        }

        return lines.joined(separator: "\n")
    }

    static func text(from metadata: RecordingSessionMetadata?) -> String? {
        text(
            sceneRaw: metadata?.sceneTemplate ?? RecordingSceneTemplate.meeting.rawValue,
            extraPrompt: metadata?.extraPrompt ?? ""
        )
    }
}
