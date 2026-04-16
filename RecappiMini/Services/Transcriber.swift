import Foundation

protocol AudioTranscriber: Sendable {
    func transcribe(audioURL: URL) async throws -> String
}

// Gemini-based audio transcription (directly from audio file)
struct GeminiTranscriber: AudioTranscriber {
    let apiKey: String

    func transcribe(audioURL: URL) async throws -> String {
        let audioData = try Data(contentsOf: audioURL)
        let base64Audio = audioData.base64EncodedString()

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)")!

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "inline_data": [
                                "mime_type": "audio/mp4",
                                "data": base64Audio,
                            ]
                        ],
                        [
                            "text": "Transcribe this audio recording verbatim. Include speaker labels where you can distinguish different speakers (e.g., Speaker 1, Speaker 2). Output only the transcript text, no additional commentary."
                        ],
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            print("[RecappiMini] Gemini transcription error: status=\(statusCode) body=\(responseBody.prefix(500))")
            throw TranscriberError.apiError(statusCode: statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw TranscriberError.invalidResponse
        }

        return text
    }
}

// OpenAI Whisper-based transcription
struct OpenAITranscriber: AudioTranscriber {
    let apiKey: String

    func transcribe(audioURL: URL) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        let audioData = try Data(contentsOf: audioURL)

        let boundary = UUID().uuidString
        var body = Data()

        // Add model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)

        // Add file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TranscriberError.apiError(statusCode: statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = json?["text"] as? String else {
            throw TranscriberError.invalidResponse
        }

        return text
    }
}

@MainActor
func createTranscriber(config: AppConfig) -> AudioTranscriber? {
    switch config.selectedProvider {
    case .none:
        return nil
    case .gemini:
        return GeminiTranscriber(apiKey: config.geminiApiKey)
    case .openai:
        return OpenAITranscriber(apiKey: config.openaiApiKey)
    }
}

enum TranscriberError: LocalizedError {
    case apiError(statusCode: Int)
    case invalidResponse
    case noTranscriberConfigured

    var errorDescription: String? {
        switch self {
        case .apiError(let code): return "Transcription API error (status \(code))"
        case .invalidResponse: return "Invalid response from transcription API"
        case .noTranscriberConfigured: return "No LLM provider configured. Set one in Settings to enable transcription."
        }
    }
}
