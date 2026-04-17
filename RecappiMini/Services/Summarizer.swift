import Foundation

protocol SummaryProvider: Sendable {
    func summarize(transcript: String) async throws -> String
}

struct NoSummarizer: SummaryProvider {
    func summarize(transcript: String) async throws -> String {
        return ""
    }
}

struct GeminiSummarizer: SummaryProvider {
    let apiKey: String
    let systemPrompt: String

    func summarize(transcript: String) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)")!

        let fullPrompt = """
        \(systemPrompt)

        Transcript:
        \(transcript)
        """

        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": fullPrompt]]]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

        return "# Meeting Summary\n\n\(text)\n"
    }
}

struct OpenAISummarizer: SummaryProvider {
    let apiKey: String
    let systemPrompt: String

    func summarize(transcript: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": transcript],
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

        return "# Meeting Summary\n\n\(text)\n"
    }
}

@MainActor
func createSummarizer(config: AppConfig) -> SummaryProvider {
    let prompt = config.summaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? AppConfig.defaultSummaryPrompt
        : config.summaryPrompt
    switch config.selectedProvider {
    case .none:
        return NoSummarizer()
    case .gemini:
        return GeminiSummarizer(apiKey: config.geminiApiKey, systemPrompt: prompt)
    case .openai:
        return OpenAISummarizer(apiKey: config.openaiApiKey, systemPrompt: prompt)
    }
}

enum SummarizerError: LocalizedError {
    case apiError(statusCode: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .apiError(let code): return "API request failed with status \(code)"
        case .invalidResponse: return "Invalid response from API"
        }
    }
}
