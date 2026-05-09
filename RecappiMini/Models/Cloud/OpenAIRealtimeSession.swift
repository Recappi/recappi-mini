import Foundation

struct OpenAIRealtimeTranscriptionSessionRequest: Encodable {
    let mode = "transcription"
    let language: String
    let delay: String
    let expiresAfterSeconds: Int
    let turnDetection: OpenAIRealtimeTurnDetection

    enum CodingKeys: String, CodingKey {
        case mode
        case language
        case delay
        case expiresAfterSeconds
        case turnDetection
    }
}

/// Bilingual mode session — OpenAI Realtime translation endpoint.
/// `includeSourceTranscript = true` makes a single connection emit
/// both the source-language transcript (`session.input_transcript.delta`)
/// and the translated transcript (`session.output_transcript.delta`),
/// so we don't need a parallel transcription session for the same
/// audio. The endpoint is a continuous stream — there are no `final`
/// or `committed` events; the client must do its own segmentation.
struct OpenAIRealtimeTranslationSessionRequest: Encodable {
    let mode = "translation"
    /// Source-language hint forwarded to the upstream Whisper model.
    let language: String
    /// Target language for the translated transcript (e.g. `zh`,
    /// `en`, `ja`). Maps directly to the `target_language` field on
    /// the OpenAI translation session config.
    let targetLanguage: String
    let delay: String
    let expiresAfterSeconds: Int
    /// Always true: callers want the source transcript alongside the
    /// translation. Without this, only `output_transcript` events arrive
    /// and the bilingual UI has no source row to render.
    let includeSourceTranscript: Bool

    enum CodingKeys: String, CodingKey {
        case mode
        case language
        case targetLanguage
        case delay
        case expiresAfterSeconds
        case includeSourceTranscript
    }
}

struct OpenAIRealtimeTurnDetection: Encodable {
    let type: String

    static let none = OpenAIRealtimeTurnDetection(type: "none")
}

struct OpenAIRealtimeSessionClaim: Decodable, Sendable {
    let sessionId: String
    let mode: String
    let websocketUrl: String
    let token: String
    let tokenType: String
    let expiresAt: Int
    let quota: OpenAIRealtimeQuotaSnapshot
}

struct OpenAIRealtimeQuotaSnapshot: Decodable, Sendable {
    let tier: String
    let periodStart: Int
    let periodEnd: Int
    let mintsUsed: Int
    let mintsCap: Int?
    let claimsPerMinute: Int
}
