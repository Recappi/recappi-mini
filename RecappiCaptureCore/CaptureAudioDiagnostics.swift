import AVFoundation
import Foundation

public struct CaptureAudioHealth: Codable, Equatable, Sendable {
    public let source: String
    public let bufferCount: Int
    public let includedBufferCount: Int?
    public let firstBufferUptime: TimeInterval?
    public let lastBufferUptime: TimeInterval?
    public let secondsSinceLastBuffer: TimeInterval?
    public let meterFrameCount: Int
    public let averagePeak: Float?
    public let maxPeak: Float?

    public init(
        source: String,
        bufferCount: Int,
        includedBufferCount: Int?,
        firstBufferUptime: TimeInterval?,
        lastBufferUptime: TimeInterval?,
        secondsSinceLastBuffer: TimeInterval?,
        meterFrameCount: Int,
        averagePeak: Float?,
        maxPeak: Float?
    ) {
        self.source = source
        self.bufferCount = bufferCount
        self.includedBufferCount = includedBufferCount
        self.firstBufferUptime = firstBufferUptime
        self.lastBufferUptime = lastBufferUptime
        self.secondsSinceLastBuffer = secondsSinceLastBuffer
        self.meterFrameCount = meterFrameCount
        self.averagePeak = averagePeak
        self.maxPeak = maxPeak
    }
}

public struct CaptureAudioDiagnostics: Codable, Sendable {
    public struct FileInfo: Codable, Equatable, Sendable {
        public let role: String
        public let fileName: String
        public let exists: Bool
        public let byteCount: Int64?
        public let sampleRate: Double?
        public let channelCount: UInt32?
        public let durationSeconds: Double?
        public let error: String?

        public init(role: String, url: URL) {
            self.role = role
            self.fileName = url.lastPathComponent
            self.exists = FileManager.default.fileExists(atPath: url.path)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            byteCount = attributes?[.size] as? Int64

            do {
                let file = try AVAudioFile(forReading: url)
                sampleRate = file.fileFormat.sampleRate
                channelCount = file.fileFormat.channelCount
                durationSeconds = file.fileFormat.sampleRate > 0
                    ? Double(file.length) / file.fileFormat.sampleRate
                    : nil
                error = nil
            } catch {
                sampleRate = nil
                channelCount = nil
                durationSeconds = nil
                self.error = error.localizedDescription
            }
        }
    }

    public let createdAt: Date
    public let sources: [FileInfo]
    public let output: FileInfo?
    public let captureHealth: [CaptureAudioHealth]

    public init(
        createdAt: Date = Date(),
        sources: [URL],
        output: URL?,
        captureHealth: [CaptureAudioHealth] = []
    ) {
        self.createdAt = createdAt
        self.sources = sources.map { FileInfo(role: Self.role(for: $0), url: $0) }
        self.output = output.map { FileInfo(role: "mixed", url: $0) }
        self.captureHealth = captureHealth
    }

    @discardableResult
    public static func write(
        sources: [URL],
        output: URL?,
        to sessionDir: URL,
        captureHealth: [CaptureAudioHealth] = []
    ) throws -> CaptureAudioDiagnostics {
        let diagnostics = CaptureAudioDiagnostics(
            sources: sources,
            output: output,
            captureHealth: captureHealth
        )
        try diagnostics.write(to: sessionDir)
        return diagnostics
    }

    public func write(to sessionDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: sessionDir.appendingPathComponent("audio-capture.json"))
    }

    public var artifactDurationMs: Int64? {
        guard let seconds = output?.durationSeconds else { return nil }
        return Int64(max(0, seconds * 1_000).rounded())
    }

    public var artifactDiagnostics: [String: String] {
        var fields: [String: String] = [
            "source.count": "\(sources.count)",
        ]
        for source in sources {
            source.appendArtifactDiagnostics(to: &fields)
        }
        output?.appendArtifactDiagnostics(to: &fields)
        return fields
    }

    private static func role(for url: URL) -> String {
        switch url.deletingPathExtension().lastPathComponent {
        case "system": "system"
        case "mic": "mic"
        default: "source"
        }
    }
}

private extension CaptureAudioDiagnostics.FileInfo {
    func appendArtifactDiagnostics(to fields: inout [String: String]) {
        let prefix = role
        fields["\(prefix).fileName"] = fileName
        fields["\(prefix).exists"] = exists ? "true" : "false"
        if let byteCount {
            fields["\(prefix).byteCount"] = "\(byteCount)"
        }
        if let sampleRate {
            fields["\(prefix).sampleRate"] = Self.format(sampleRate)
        }
        if let channelCount {
            fields["\(prefix).channelCount"] = "\(channelCount)"
        }
        if let durationSeconds {
            fields["\(prefix).durationSeconds"] = Self.format(durationSeconds)
        }
        if let error {
            fields["\(prefix).error"] = error
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
