import Foundation

public protocol RecordingCaptureCore: Sendable {
    func availableSources() async throws -> [CaptureSource]
    func availableMicrophones() async throws -> [MicrophoneDevice]
    func permissionStatus(for selection: CaptureSelection) async -> CapturePermissions
    func requestPermissions(for selection: CaptureSelection) async throws -> CapturePermissions
    func start(_ selection: CaptureSelection, metadata: CaptureSessionMetadata) async throws -> CaptureSession
}

public protocol CaptureSession: Sendable {
    var states: AsyncStream<CaptureState> { get }
    var levels: AsyncStream<CaptureLevel> { get }

    func pause() async throws
    func resume() async throws
    func stop() async throws -> CaptureArtifact
    func cancel() async
}

public struct CaptureSource: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case system
        case app
    }

    public var id: String
    public var kind: Kind
    public var label: String
    public var appName: String?
    public var bundleID: String?

    public init(
        id: String,
        kind: Kind,
        label: String,
        appName: String? = nil,
        bundleID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.appName = appName
        self.bundleID = bundleID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case label
        case appName
        case bundleID = "bundleId"
    }
}

public struct MicrophoneDevice: Sendable, Codable, Equatable {
    public var id: String
    public var label: String
    public var isDefault: Bool

    public init(id: String, label: String, isDefault: Bool = false) {
        self.id = id
        self.label = label
        self.isDefault = isDefault
    }
}

public struct CaptureSelection: Sendable, Codable, Equatable {
    public var sourceID: String
    public var includeMicrophone: Bool
    public var microphoneDeviceID: String?

    public init(
        sourceID: String,
        includeMicrophone: Bool,
        microphoneDeviceID: String? = nil
    ) {
        self.sourceID = sourceID
        self.includeMicrophone = includeMicrophone
        self.microphoneDeviceID = microphoneDeviceID
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID = "sourceId"
        case includeMicrophone
        case microphoneDeviceID = "microphoneDeviceId"
    }
}

public struct CapturePermissions: Sendable, Codable, Equatable {
    public var screenRecording: CapturePermission
    public var microphone: CapturePermission?

    public init(screenRecording: CapturePermission, microphone: CapturePermission? = nil) {
        self.screenRecording = screenRecording
        self.microphone = microphone
    }
}

public struct CapturePermission: Sendable, Codable, Equatable {
    public enum Status: String, Sendable, Codable {
        case granted
        case denied
        case unknown
    }

    public var status: Status
    public var requiresProcessRestart: Bool

    public init(status: Status, requiresProcessRestart: Bool = false) {
        self.status = status
        self.requiresProcessRestart = requiresProcessRestart
    }
}

public struct CaptureState: Sendable, Codable, Equatable {
    public enum Status: String, Sendable, Codable {
        case idle
        case starting
        case recording
        case paused
        case stopping
        case finalizing
        case completed
        case failed
        case cancelled
    }

    public var sessionID: String
    public var status: Status
    public var message: String?
    public var atMs: Int64?

    public init(
        sessionID: String,
        status: Status,
        message: String? = nil,
        atMs: Int64? = nil
    ) {
        self.sessionID = sessionID
        self.status = status
        self.message = message
        self.atMs = atMs
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case status
        case message
        case atMs
    }
}

public struct CaptureLevel: Sendable, Codable, Equatable {
    public enum Input: String, Sendable, Codable {
        case system
        case microphone
    }

    public var input: Input
    public var rmsDb: Float
    public var atMs: Int64

    public init(input: Input, rmsDb: Float, atMs: Int64) {
        self.input = input
        self.rmsDb = rmsDb
        self.atMs = atMs
    }
}

public struct CaptureSessionMetadata: Sendable, Codable, Equatable {
    public var sessionID: String
    public var title: String?
    public var createdAt: Date

    public init(sessionID: String, title: String? = nil, createdAt: Date = Date()) {
        self.sessionID = sessionID
        self.title = title
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case title
        case createdAt
    }
}

public struct CaptureArtifact: Sendable, Codable, Equatable {
    public var sessionDirectoryURL: URL
    public var mixedAudioURL: URL?
    public var systemAudioURL: URL?
    public var microphoneAudioURL: URL?
    public var durationMs: Int64?
    public var diagnostics: [String: String]
    public var effectiveSelection: CaptureSelection

    public init(
        sessionDirectoryURL: URL,
        mixedAudioURL: URL? = nil,
        systemAudioURL: URL? = nil,
        microphoneAudioURL: URL? = nil,
        durationMs: Int64? = nil,
        diagnostics: [String: String] = [:],
        effectiveSelection: CaptureSelection
    ) {
        self.sessionDirectoryURL = sessionDirectoryURL
        self.mixedAudioURL = mixedAudioURL
        self.systemAudioURL = systemAudioURL
        self.microphoneAudioURL = microphoneAudioURL
        self.durationMs = durationMs
        self.diagnostics = diagnostics
        self.effectiveSelection = effectiveSelection
    }
}
