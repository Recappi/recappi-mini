import Foundation
import FoundationModels

/// On-device Apple Intelligence summarizer via the Foundation Models API.
/// Free, private, no API key. Requires Apple Intelligence enabled in System
/// Settings; throws `appleIntelligenceUnavailable` otherwise so the error
/// surfaces in the panel.
///
/// Built with the runtime `DynamicGenerationSchema` API rather than the
/// `@Generable` macro — the macro needs the FoundationModelsMacros compiler
/// plugin which only ships with Xcode, not the Command Line Tools.
struct AppleInsightsProvider: InsightsProvider {
    func extract(transcript: String) async throws -> MeetingInsights {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw SummarizerError.appleIntelligenceUnavailable
        }

        let session = LanguageModelSession(
            model: model,
            instructions: """
            You are an assistant summarizing meeting transcripts. Produce a
            concise summary, a list of key decisions, and action items with
            owner and due date when stated. Don't invent content that isn't
            in the transcript.
            """
        )

        let schema = try Self.makeSchema()
        let response = try await session.respond(
            to: "Meeting transcript:\n\n\(transcript)",
            schema: schema
        )

        return Self.decode(response.content)
    }

    // MARK: - Schema

    private static func makeSchema() throws -> GenerationSchema {
        let stringSchema = DynamicGenerationSchema(type: String.self)

        let actionItemSchema = DynamicGenerationSchema(
            name: "ActionItem",
            properties: [
                .init(
                    name: "owner",
                    description: "Person responsible. Empty string if not named in transcript.",
                    schema: stringSchema
                ),
                .init(
                    name: "text",
                    description: "The task to be done.",
                    schema: stringSchema
                ),
                .init(
                    name: "due",
                    description: "Due date as plain text. Empty string if not stated.",
                    schema: stringSchema
                ),
            ]
        )

        let insightsSchema = DynamicGenerationSchema(
            name: "MeetingInsights",
            properties: [
                .init(
                    name: "summary",
                    description: "Concise markdown summary, 3-5 short paragraphs. Use ## headings where useful.",
                    schema: stringSchema
                ),
                .init(
                    name: "keyDecisions",
                    description: "Concrete decisions reached in the meeting.",
                    schema: DynamicGenerationSchema(arrayOf: stringSchema)
                ),
                .init(
                    name: "actionItems",
                    description: "Tasks with owner and due date where stated.",
                    schema: DynamicGenerationSchema(arrayOf: actionItemSchema)
                ),
            ]
        )

        return try GenerationSchema(root: insightsSchema, dependencies: [actionItemSchema])
    }

    // MARK: - Decoding

    private static func decode(_ content: GeneratedContent) -> MeetingInsights {
        let summary = (try? content.value(String.self, forProperty: "summary")) ?? ""
        let decisions = ((try? content.value([String].self, forProperty: "keyDecisions")) ?? [])
            .filter { !$0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty }

        let rawItems = (try? content.value([GeneratedContent].self, forProperty: "actionItems")) ?? []
        let items: [MeetingInsights.ActionItem] = rawItems.compactMap { itemContent in
            let text = ((try? itemContent.value(String.self, forProperty: "text")) ?? "")
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let owner = (try? itemContent.value(String.self, forProperty: "owner")) ?? ""
            let due = (try? itemContent.value(String.self, forProperty: "due")) ?? ""
            return MeetingInsights.ActionItem(
                owner: owner.isEmpty ? nil : owner,
                text: text,
                due: due.isEmpty ? nil : due
            )
        }

        return MeetingInsights(
            summary: summary,
            keyDecisions: decisions,
            actionItems: items
        )
    }
}
