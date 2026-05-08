import Foundation

struct OpenAIRealtimeTranscriptionSessionRequest: Encodable {
    let mode = "transcription"
    let language: String
    let delay: String
    let expiresAfterSeconds: Int
    let turnDetection: OpenAIRealtimeServerVAD

    enum CodingKeys: String, CodingKey {
        case mode
        case language
        case delay
        case expiresAfterSeconds
        case turnDetection
    }
}

struct OpenAIRealtimeServerVAD: Encodable {
    let type = "server_vad"
    let threshold: Double
    let prefixPaddingMs: Int
    let silenceDurationMs: Int

    enum CodingKeys: String, CodingKey {
        case type
        case threshold
        case prefixPaddingMs
        case silenceDurationMs
    }
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
