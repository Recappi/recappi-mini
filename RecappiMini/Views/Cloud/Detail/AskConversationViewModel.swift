import Foundation
import SwiftUI

/// A single turn rendered in the Ask conversation. Distinct from the wire
/// `AskThreadMessage` so the streaming assistant turn can be mutated in place.
struct AskConversationMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    enum Status: Equatable {
        case complete
        case streaming
        case failed(String)
    }

    let id: String
    let role: Role
    var content: String
    var citations: [AskCitation]
    var status: Status

    init(
        id: String = UUID().uuidString,
        role: Role,
        content: String,
        citations: [AskCitation] = [],
        status: Status = .complete
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.citations = citations
        self.status = status
    }
}

@MainActor
final class AskConversationViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loadingHistory
        case streaming
        case error(String)
    }

    @Published var messages: [AskConversationMessage] = []
    @Published var draft: String = ""
    @Published var webSearch: Bool = false
    @Published var phase: Phase = .idle
    @Published var streamingText: String = ""
    @Published var suggestions: [String] = []

    private let recordingId: String
    private let store: CloudLibraryStore
    private var streamTask: Task<Void, Never>?
    private var didLoad = false

    /// Static fallback suggestions when the backend endpoint returns nothing.
    private static let fallbackSuggestions = [
        "Summarize the key decisions",
        "What are the action items?",
        "Who said what about the timeline?",
    ]

    init(recordingId: String, store: CloudLibraryStore) {
        self.recordingId = recordingId
        self.store = store
    }

    var isStreaming: Bool {
        if case .streaming = phase { return true }
        return false
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
    }

    /// Load history once. Safe to call repeatedly (e.g. on each popover open).
    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        Task { await load() }
        Task { await loadSuggestions() }
    }

    func load() async {
        phase = .loadingHistory
        do {
            let history = try await store.loadAskThread(recordingId: recordingId)
            messages = history.map { msg in
                AskConversationMessage(
                    id: msg.id,
                    role: msg.role == .user ? .user : .assistant,
                    content: msg.content,
                    citations: msg.citations.map(\.asCitation),
                    status: .complete
                )
            }
            phase = .idle
        } catch let error as DecodingError {
            // A decode mismatch is a real bug — surface it instead of silently
            // showing an empty thread (which previously hid the history failure).
            messages = []
            phase = .error("Couldn't load history: \(error)")
        } catch {
            // An empty / not-yet-created thread or transient network failure is
            // not worth surfacing.
            messages = []
            phase = .idle
        }
    }

    func loadSuggestions() async {
        let fetched = await store.loadAskSuggestions(recordingId: recordingId)
        suggestions = fetched.isEmpty ? Self.fallbackSuggestions : fetched
    }

    func useSuggestion(_ text: String) {
        guard !isStreaming else { return }
        draft = text
        send()
    }

    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming else { return }
        draft = ""

        let userMessage = AskConversationMessage(role: .user, content: question)
        let assistantId = UUID().uuidString
        let assistantMessage = AskConversationMessage(
            id: assistantId,
            role: .assistant,
            content: "",
            status: .streaming
        )
        messages.append(userMessage)
        messages.append(assistantMessage)
        streamingText = ""
        phase = .streaming

        let webSearch = self.webSearch
        let recordingId = self.recordingId
        let store = self.store

        streamTask = Task { [weak self] in
            var accumulated = ""
            var citations: [AskCitation] = []
            do {
                let stream = store.askThreadEvents(
                    recordingId: recordingId,
                    question: question,
                    webSearch: webSearch
                )
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .metadata:
                        break
                    case .answerDelta(let delta):
                        accumulated += delta
                        self?.applyStreaming(id: assistantId, text: accumulated)
                    case .citation(let citation):
                        if !citations.contains(where: { $0.id == citation.id }) {
                            citations.append(citation)
                        }
                        self?.applyCitations(id: assistantId, citations: citations)
                    case .done(let doneCitations):
                        if !doneCitations.isEmpty {
                            citations = doneCitations
                        }
                    }
                }
                self?.finalize(id: assistantId, text: accumulated, citations: citations)
            } catch {
                self?.fail(id: assistantId, error: error, partial: accumulated)
            }
        }
    }

    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        if isStreaming {
            // Finalize whatever was streamed so the partial answer stays visible.
            if let index = messages.firstIndex(where: { $0.status == .streaming }) {
                messages[index].status = .complete
            }
            phase = .idle
        }
    }

    // MARK: - Mutations

    /// Strip inline citation markers like `[[seg-18]]` (and stray `[seg-18]`)
    /// from displayed answer text. The streaming `answer_delta` deltas carry
    /// these markers (only the backend's final persisted content is clean); the
    /// sources are surfaced separately as citation chips, so we hide the markers.
    static func strippedDisplay(_ text: String) -> String {
        var out = text.replacingOccurrences(
            of: #"\[\[seg-[^\]]*\]\]"#, with: "", options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"\[seg-[^\]]*\]"#, with: "", options: .regularExpression
        )
        return out
    }

    private func applyStreaming(id: String, text: String) {
        streamingText = text
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content = Self.strippedDisplay(text)
    }

    private func applyCitations(id: String, citations: [AskCitation]) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].citations = citations
    }

    private func finalize(id: String, text: String, citations: [AskCitation]) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].content = Self.strippedDisplay(text)
            messages[index].citations = citations
            messages[index].status = .complete
        }
        streamingText = ""
        phase = .idle
    }

    private func fail(id: String, error: Error, partial: String) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        // Keep the assistant bubble (even with no partial text) and mark it
        // failed so the error is always visible to the user instead of silently
        // vanishing.
        if let index = messages.firstIndex(where: { $0.id == id }) {
            if partial.isEmpty {
                messages[index].content = ""
            }
            messages[index].status = .failed(message)
        }
        streamingText = ""
        phase = .error(message)
    }
}
