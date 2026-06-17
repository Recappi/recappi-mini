import Foundation

// MARK: - Ask thread GET (history) models

/// One persisted citation as returned by `GET /api/recordings/:id/ask-thread`.
/// Shape matches the nested `citations` array of each message.
struct AskThreadCitation: Decodable, Sendable, Equatable {
    let segmentId: String?
    let index: Int?
    let startMs: Int?
    let endMs: Int?
    let label: String?
    let speaker: String?
    let snippet: String?

    var asCitation: AskCitation {
        AskCitation(
            segmentId: segmentId,
            index: index,
            startMs: startMs,
            endMs: endMs,
            label: label,
            speaker: speaker,
            snippet: snippet
        )
    }
}

/// One persisted message in the Ask thread. `content` is already clean plain
/// text (no `[[seg-N]]` markers); citations carry the source ranges.
struct AskThreadMessage: Decodable, Sendable, Identifiable, Equatable {
    enum Role: String, Decodable, Sendable, Equatable {
        case user
        case assistant
    }

    let id: String
    let role: Role
    let status: String?
    let content: String
    let webSearch: Bool?
    let model: String?
    // Epoch milliseconds (the backend sends these as numbers, not strings).
    let createdAt: Double?
    let updatedAt: Double?
    let citations: [AskThreadCitation]

    enum CodingKeys: String, CodingKey {
        case id, role, status, content, webSearch, model, createdAt, updatedAt, citations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = (try? container.decode(Role.self, forKey: .role)) ?? .assistant
        status = try container.decodeIfPresent(String.self, forKey: .status)
        content = (try container.decodeIfPresent(String.self, forKey: .content)) ?? ""
        webSearch = try container.decodeIfPresent(Bool.self, forKey: .webSearch)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt)
        citations = (try container.decodeIfPresent([AskThreadCitation].self, forKey: .citations)) ?? []
    }

    init(
        id: String,
        role: Role,
        status: String?,
        content: String,
        webSearch: Bool?,
        model: String?,
        createdAt: Double?,
        updatedAt: Double?,
        citations: [AskThreadCitation]
    ) {
        self.id = id
        self.role = role
        self.status = status
        self.content = content
        self.webSearch = webSearch
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.citations = citations
    }
}

private struct AskThreadResponse: Decodable {
    let messages: [AskThreadMessage]
}

private struct AskSuggestionsResponse: Decodable {
    let suggestions: [String]
}

// MARK: - SSE event payload decoding

private struct AskMetadataPayload: Decodable {
    let segmentCount: Int?
}

private struct AskDeltaPayload: Decodable {
    let delta: String?
}

/// `citation` frames nest the citation under a `citation` key.
private struct AskCitationPayload: Decodable {
    let citation: AskThreadCitation
}

private struct AskDonePayload: Decodable {
    let citations: [AskThreadCitation]?
}

private struct AskErrorPayload: Decodable {
    let message: String?
    let error: String?
}

/// A clear, surfaced error from the Ask backend so the UI can present a
/// human-readable message (transcript not ready, signed out, overloaded, …).
enum AskStreamError: LocalizedError, Equatable {
    case transcriptNotReady
    case unauthorized
    case overloaded
    case server(message: String)

    var errorDescription: String? {
        switch self {
        case .transcriptNotReady:
            return "The transcript isn’t ready yet. Try again once processing finishes."
        case .unauthorized:
            return "Recappi Cloud session expired. Sign in again to continue."
        case .overloaded:
            return "The assistant is busy right now. Please try again in a moment."
        case .server(let message):
            return message
        }
    }
}

extension RecappiAPIClient {
    private struct AskMessageRequest: Encodable {
        let question: String
        let webSearch: Bool
        let model: String?
    }

    /// Fetch the persisted Ask thread (history) for a recording.
    func fetchAskThread(recordingId: String) async throws -> [AskThreadMessage] {
        let request = try makeRequest(path: "/api/recordings/\(recordingId)/ask-thread")
        let (data, _) = try await performValidated(request)
        return try JSONDecoder().decode(AskThreadResponse.self, from: data).messages
    }

    /// Fetch follow-up suggestions for a recording. Returns an empty array on
    /// any failure so the caller can fall back to static suggestions.
    func fetchAskSuggestions(recordingId: String, language: String?) async -> [String] {
        let queryItems = language.map { [URLQueryItem(name: "language", value: $0)] } ?? []
        guard let request = try? makeRequest(
            path: "/api/recordings/\(recordingId)/ask-suggestions",
            queryItems: queryItems
        ) else { return [] }
        guard let (data, _) = try? await performValidated(request) else { return [] }
        return (try? JSONDecoder().decode(AskSuggestionsResponse.self, from: data).suggestions) ?? []
    }

    /// Stream an Ask answer over SSE. Posts the question and yields decoded
    /// `AskStreamEvent`s; throws an `AskStreamError` on an `error` frame or a
    /// non-2xx status.
    func askThreadStream(
        recordingId: String,
        question: String,
        webSearch: Bool,
        model: String? = nil
    ) -> AsyncThrowingStream<AskStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try makeRequest(
                        path: "/api/recordings/\(recordingId)/ask-thread/messages",
                        method: "POST"
                    )
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(
                        AskMessageRequest(question: question, webSearch: webSearch, model: model)
                    )

                    let (bytes, response) = try await session.bytes(for: request)

                    if let http = response as? HTTPURLResponse,
                       !(200...299).contains(http.statusCode) {
                        throw Self.mapAskStatus(http.statusCode, bytes: bytes)
                    }

                    // Parse SSE by splitting the byte stream on the blank-line
                    // frame delimiter (\n\n) directly, rather than relying on
                    // `bytes.lines` to surface the empty separator lines — it does
                    // not do so reliably, which made every frame accumulate and
                    // only the final frame flush (so answer_delta never streamed).
                    // Decoding each frame's bytes as UTF-8 also keeps multibyte
                    // (CJK) answer text intact.
                    func processFrame(_ frameText: String) throws {
                        var eventName: String?
                        var dataLines: [String] = []
                        for rawLine in frameText.split(separator: "\n", omittingEmptySubsequences: false) {
                            var line = String(rawLine)
                            if line.hasSuffix("\r") { line.removeLast() }
                            if line.isEmpty || line.hasPrefix(":") { continue }
                            if line.hasPrefix("event:") {
                                eventName = String(line.dropFirst("event:".count))
                                    .trimmingCharacters(in: .whitespaces)
                            } else if line.hasPrefix("data:") {
                                var value = String(line.dropFirst("data:".count))
                                if value.hasPrefix(" ") { value.removeFirst() }
                                dataLines.append(value)
                            }
                        }
                        guard !dataLines.isEmpty else { return }
                        if let event = try Self.decodeAskEvent(
                            name: eventName ?? "message",
                            data: dataLines.joined(separator: "\n")
                        ) {
                            continuation.yield(event)
                        }
                    }

                    var buffer = Data()
                    let delimiter = Data([0x0a, 0x0a]) // "\n\n"
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        buffer.append(byte)
                        guard byte == 0x0a else { continue }
                        while let range = buffer.range(of: delimiter) {
                            let frameData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                            if let text = String(data: frameData, encoding: .utf8) {
                                try processFrame(text)
                            }
                        }
                    }
                    // Flush any trailing frame not terminated by a blank line.
                    if let text = String(data: buffer, encoding: .utf8), !text.isEmpty {
                        try processFrame(text)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Map an SSE frame into an `AskStreamEvent`. Returns `nil` for frames the
    /// UI does not need (e.g. unknown event names). Throws for `error` frames.
    private static func decodeAskEvent(name: String, data: String) throws -> AskStreamEvent? {
        let bytes = Data(data.utf8)
        switch name {
        case "metadata":
            let payload = try? JSONDecoder().decode(AskMetadataPayload.self, from: bytes)
            return .metadata(segmentCount: payload?.segmentCount)
        case "answer_delta":
            let payload = try? JSONDecoder().decode(AskDeltaPayload.self, from: bytes)
            return .answerDelta(payload?.delta ?? "")
        case "citation":
            guard let payload = try? JSONDecoder().decode(AskCitationPayload.self, from: bytes) else {
                return nil
            }
            return .citation(payload.citation.asCitation)
        case "done":
            let payload = try? JSONDecoder().decode(AskDonePayload.self, from: bytes)
            let citations = (payload?.citations ?? []).map(\.asCitation)
            return .done(citations: citations)
        case "error":
            let payload = try? JSONDecoder().decode(AskErrorPayload.self, from: bytes)
            let message = payload?.message ?? payload?.error ?? "The assistant ran into an error."
            throw AskStreamError.server(message: message)
        default:
            return nil
        }
    }

    private static func mapAskStatus(_ statusCode: Int, bytes: URLSession.AsyncBytes) -> AskStreamError {
        switch statusCode {
        case 401:
            return .unauthorized
        case 409:
            return .transcriptNotReady
        case 503:
            return .overloaded
        default:
            return .server(message: "Ask request failed (status \(statusCode)).")
        }
    }
}
