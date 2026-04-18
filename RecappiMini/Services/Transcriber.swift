import AVFoundation
import Foundation
import Speech

protocol AudioTranscriber: Sendable {
    func transcribe(audioURL: URL) async throws -> String
}

// MARK: - Apple Speech (local, free, default)

/// On-device Apple Speech. Transparently chunks long recordings since
/// SFSpeechRecognizer effectively caps around a minute per call.
struct AppleSpeechTranscriber: AudioTranscriber {
    let language: String

    /// Chunk size kept under the ~60s SFSpeechRecognizer effective cap with
    /// headroom. At 32kbps AAC each 50s chunk is ~200KB — negligible to split.
    private static let chunkSeconds: Double = 50

    func transcribe(audioURL: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            throw TranscriberError.speechLanguageNotSupported(language)
        }
        guard recognizer.isAvailable else {
            throw TranscriberError.speechUnavailable
        }

        let authStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard authStatus == .authorized else {
            throw TranscriberError.speechNotAuthorized
        }

        let workingDir = audioURL.deletingLastPathComponent().appendingPathComponent(".chunks", isDirectory: true)
        let chunks = try await AudioChunker.split(
            source: audioURL,
            chunkSeconds: Self.chunkSeconds,
            into: workingDir
        )
        defer {
            AudioChunker.cleanup(chunks, keepingOriginal: audioURL)
            try? FileManager.default.removeItem(at: workingDir)
        }

        var pieces: [String] = []
        for chunk in chunks {
            let text = try await Self.recognize(url: chunk.url, using: recognizer)
            if !text.isEmpty { pieces.append(text) }
        }
        return pieces.joined(separator: " ")
    }

    private static func recognize(
        url: URL,
        using recognizer: SFSpeechRecognizer
    ) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { cont in
            // Guard resume via a box so the timeout closure can see the final state.
            final class ResumeGate: @unchecked Sendable {
                var done = false
                let lock = NSLock()
                func tryResume() -> Bool {
                    lock.lock(); defer { lock.unlock() }
                    if done { return false }
                    done = true
                    return true
                }
            }
            let gate = ResumeGate()

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if gate.tryResume() { cont.resume(throwing: error) }
                    return
                }
                guard let result, result.isFinal else { return }
                if gate.tryResume() {
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }

            // Per-chunk timeout: 90s is generous given chunks are <= 50s audio.
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) { [gate] in
                if gate.tryResume() {
                    task.cancel()
                    cont.resume(throwing: TranscriberError.speechTimedOut)
                }
            }
        }
    }
}

// MARK: - Gemini (remote, chunks only if file exceeds inline limit)

struct GeminiTranscriber: AudioTranscriber {
    let apiKey: String

    /// Gemini inline upload limit is 20MB. Stay well under so the base64
    /// overhead and JSON framing don't push us over. ~15MB at 32kbps is ~65
    /// minutes, which fits most meetings in a single call.
    private static let inlineByteLimit: Int = 15 * 1024 * 1024

    /// Fallback chunk length when a single recording exceeds the inline cap.
    private static let chunkSeconds: Double = 30 * 60

    func transcribe(audioURL: URL) async throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        if size <= Self.inlineByteLimit {
            return try await transcribeOne(url: audioURL)
        }

        let workingDir = audioURL.deletingLastPathComponent().appendingPathComponent(".chunks", isDirectory: true)
        let chunks = try await AudioChunker.split(
            source: audioURL,
            chunkSeconds: Self.chunkSeconds,
            into: workingDir
        )
        defer {
            AudioChunker.cleanup(chunks, keepingOriginal: audioURL)
            try? FileManager.default.removeItem(at: workingDir)
        }

        var pieces: [String] = []
        for chunk in chunks {
            let text = try await transcribeOne(url: chunk.url)
            if !text.isEmpty { pieces.append(text) }
        }
        return pieces.joined(separator: "\n\n")
    }

    private func transcribeOne(url: URL) async throws -> String {
        let audioData = try Data(contentsOf: url)
        let base64Audio = audioData.base64EncodedString()

        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)")!

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

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
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

// MARK: - OpenAI Whisper (remote, also chunked when over the 25MB upload cap)

struct OpenAITranscriber: AudioTranscriber {
    let apiKey: String

    /// Whisper caps at 25MB per request. Keep margin.
    private static let uploadByteLimit: Int = 24 * 1024 * 1024
    private static let chunkSeconds: Double = 30 * 60

    func transcribe(audioURL: URL) async throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        if size <= Self.uploadByteLimit {
            return try await transcribeOne(url: audioURL)
        }

        let workingDir = audioURL.deletingLastPathComponent().appendingPathComponent(".chunks", isDirectory: true)
        let chunks = try await AudioChunker.split(
            source: audioURL,
            chunkSeconds: Self.chunkSeconds,
            into: workingDir
        )
        defer {
            AudioChunker.cleanup(chunks, keepingOriginal: audioURL)
            try? FileManager.default.removeItem(at: workingDir)
        }

        var pieces: [String] = []
        for chunk in chunks {
            let text = try await transcribeOne(url: chunk.url)
            if !text.isEmpty { pieces.append(text) }
        }
        return pieces.joined(separator: "\n\n")
    }

    private func transcribeOne(url: URL) async throws -> String {
        let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        let audioData = try Data(contentsOf: url)

        let boundary = UUID().uuidString
        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 180

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

// MARK: - Factory

/// Default path is local Apple Speech. Remote providers are only used when
/// explicitly configured — keeps us free-by-default and offline-capable.
@MainActor
func createTranscriber(config: AppConfig) -> AudioTranscriber {
    switch config.selectedProvider {
    case .none:
        return AppleSpeechTranscriber(language: config.speechLanguage)
    case .gemini:
        return GeminiTranscriber(apiKey: config.geminiApiKey)
    case .openai:
        return OpenAITranscriber(apiKey: config.openaiApiKey)
    }
}

// MARK: - Errors

enum TranscriberError: LocalizedError {
    case apiError(statusCode: Int)
    case invalidResponse
    case speechLanguageNotSupported(String)
    case speechUnavailable
    case speechNotAuthorized
    case speechTimedOut

    var errorDescription: String? {
        switch self {
        case .apiError(let code): return "Transcription API error (status \(code))"
        case .invalidResponse: return "Invalid response from transcription API"
        case .speechLanguageNotSupported(let lang): return "Speech language not supported: \(lang)"
        case .speechUnavailable: return "Speech recognizer unavailable"
        case .speechNotAuthorized: return "Speech recognition not authorized. Enable in System Settings > Privacy & Security > Speech Recognition"
        case .speechTimedOut: return "Speech recognition timed out"
        }
    }
}
