import Foundation

struct CreateRecordingRequest: Encodable {
    let title: String?
    let contentType: String
    let durationMs: Int?
}

struct CreateRecordingResponse: Decodable {
    let id: String
    let partSize: Int
    let maxPartBytes: Int
    let r2Key: String
}

struct UploadPartDescriptor: Codable, Equatable {
    let partNumber: Int
    let etag: String
}


struct CompletedRecording: Decodable {
    let id: String
    let status: String
    let contentType: String
}

