import Foundation

/// Structured output of an LLM pass over a meeting transcript.
/// We carry this through the pipeline instead of a flat string so we can
/// fan it out to multiple markdown files without the caller needing to
/// re-parse anything.
struct MeetingInsights: Sendable {
    let summary: String
    let keyDecisions: [String]
    let actionItems: [ActionItem]

    struct ActionItem: Sendable {
        let owner: String?
        let text: String
        let due: String?
    }

    static let empty = MeetingInsights(summary: "", keyDecisions: [], actionItems: [])

    var isEmpty: Bool {
        summary.isEmpty && keyDecisions.isEmpty && actionItems.isEmpty
    }
}

protocol InsightsProvider: Sendable {
    func extract(transcript: String) async throws -> MeetingInsights
}

// MARK: - No-op (when no LLM configured)

struct NoInsightsProvider: InsightsProvider {
    func extract(transcript: String) async throws -> MeetingInsights {
        .empty
    }
}

// MARK: - Shared prompt + JSON parsing

private enum InsightsPrompt {
    static let instruction = """
    You are an assistant summarizing a meeting transcript. Respond with a
    single JSON object matching this shape — do not include any prose before
    or after the JSON:

    {
      "summary": "concise markdown, 3-5 short paragraphs, with section \
    headings using ## when helpful",
      "key_decisions": ["decision 1", "decision 2"],
      "action_items": [
        {"owner": "Alice", "text": "Do the thing", "due": "next Friday"}
      ]
    }

    Rules:
    - If nothing fits a category, return an empty array for it.
    - For action_items, use an empty string for owner or due when the \
    transcript doesn't specify.
    - Do not invent content that isn't in the transcript.
    """

    /// Extracts `{"summary": ..., ...}` from the provider response. Providers
    /// sometimes wrap JSON in ```json fences, or return it embedded in prose
    /// despite instructions — be tolerant and lift out the first object block.
    static func parse(_ raw: String) throws -> MeetingInsights {
        let cleaned: String = {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("```") {
                if let firstNewline = s.firstIndex(of: "\n") {
                    s = String(s[s.index(after: firstNewline)...])
                }
                if let fence = s.range(of: "```", options: .backwards) {
                    s = String(s[..<fence.lowerBound])
                }
            }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        guard let data = cleaned.data(using: .utf8) else {
            throw SummarizerError.invalidResponse
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummarizerError.invalidResponse
        }

        let summary = (root["summary"] as? String) ?? ""
        let decisions = (root["key_decisions"] as? [String]) ?? []
        let rawItems = (root["action_items"] as? [[String: Any]]) ?? []
        let items: [MeetingInsights.ActionItem] = rawItems.compactMap { dict in
            guard let text = dict["text"] as? String, !text.isEmpty else { return nil }
            let owner = (dict["owner"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let due = (dict["due"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return MeetingInsights.ActionItem(owner: owner, text: text, due: due)
        }
        return MeetingInsights(summary: summary, keyDecisions: decisions, actionItems: items)
    }
}

// MARK: - Gemini (JSON mode)

struct GeminiInsightsProvider: InsightsProvider {
    let apiKey: String
    let baseUrl: String
    let model: String

    func extract(transcript: String) async throws -> MeetingInsights {
        let trimmedBase = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(trimmedBase)/models/\(model):generateContent?key=\(apiKey)") else {
            throw SummarizerError.invalidResponse
        }

        let fullPrompt = "\(InsightsPrompt.instruction)\n\nTranscript:\n\(transcript)"

        // response_mime_type asks Gemini for valid JSON; we still sanitise
        // in InsightsPrompt.parse because real-world responses occasionally
        // wrap with fences.
        let body: [String: Any] = [
            "contents": [["parts": [["text": fullPrompt]]]],
            "generationConfig": [
                "response_mime_type": "application/json",
                "temperature": 0.2,
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SummarizerError.apiError(statusCode: statusCode)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw SummarizerError.invalidResponse
        }
        return try InsightsPrompt.parse(text)
    }
}

// MARK: - OpenAI (JSON object mode)

struct OpenAIInsightsProvider: InsightsProvider {
    let apiKey: String
    let baseUrl: String
    let model: String

    func extract(transcript: String) async throws -> MeetingInsights {
        let trimmedBase = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(trimmedBase)/chat/completions") else {
            throw SummarizerError.invalidResponse
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": InsightsPrompt.instruction],
                ["role": "user", "content": transcript],
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.2,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SummarizerError.apiError(statusCode: statusCode)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw SummarizerError.invalidResponse
        }
        return try InsightsPrompt.parse(text)
    }
}

// MARK: - Factory

@MainActor
func createInsightsProvider(config: AppConfig) -> InsightsProvider {
    switch config.selectedProvider {
    case .none:
        return NoInsightsProvider()
    case .apple:
        return AppleInsightsProvider()
    case .gemini:
        return GeminiInsightsProvider(
            apiKey: config.geminiApiKey,
            baseUrl: config.effectiveGeminiBaseUrl,
            model: config.effectiveGeminiModel
        )
    case .openai:
        return OpenAIInsightsProvider(
            apiKey: config.openaiApiKey,
            baseUrl: config.effectiveOpenaiBaseUrl,
            model: config.effectiveOpenaiChatModel
        )
    }
}

// MARK: - Errors

enum SummarizerError: LocalizedError {
    case apiError(statusCode: Int)
    case invalidResponse
    case appleIntelligenceUnavailable

    var errorDescription: String? {
        switch self {
        case .apiError(let code): return "Summary API error (status \(code))"
        case .invalidResponse: return "Couldn't parse summary response as JSON"
        case .appleIntelligenceUnavailable:
            return "Apple Intelligence isn't available. Enable it in System Settings > Apple Intelligence, or pick a different provider in Settings."
        }
    }
}
