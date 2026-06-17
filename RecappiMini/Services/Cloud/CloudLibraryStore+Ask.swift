import Foundation

@MainActor
extension CloudLibraryStore {
    /// Load the persisted Ask thread (history) for a recording.
    func loadAskThread(recordingId: String) async throws -> [AskThreadMessage] {
        try await runAuthorized { client in
            try await client.fetchAskThread(recordingId: recordingId)
        }
    }

    /// Load follow-up suggestions for a recording. Falls back to an empty array
    /// (the view model substitutes static suggestions) on any failure.
    func loadAskSuggestions(recordingId: String) async -> [String] {
        let language = config.normalizedCloudLanguage
        return (try? await runAuthorized { client in
            await client.fetchAskSuggestions(recordingId: recordingId, language: language)
        }) ?? []
    }

    /// Stream an Ask answer. Resolves an authorized client inside the stream's
    /// backing task (mirroring `runAuthorized`'s origin + bearer resolution),
    /// then forwards the SSE events.
    func askThreadEvents(
        recordingId: String,
        question: String,
        webSearch: Bool
    ) -> AsyncThrowingStream<AskStreamEvent, Error> {
        let origin = config.effectiveBackendBaseURL
        let sessionStore = self.sessionStore

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await sessionStore.ensureAuthorized(origin: origin)
                    guard let token = sessionStore.bearerToken() else {
                        throw RecappiSessionError.notSignedIn
                    }
                    let client = RecappiAPIClient(origin: origin, bearerToken: token)
                    let stream = client.askThreadStream(
                        recordingId: recordingId,
                        question: question,
                        webSearch: webSearch
                    )
                    for try await event in stream {
                        if Task.isCancelled { break }
                        continuation.yield(event)
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
}
