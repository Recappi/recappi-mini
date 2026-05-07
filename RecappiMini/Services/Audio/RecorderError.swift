import Foundation

// MARK: - Errors

enum RecorderError: LocalizedError {
    case noDisplay
    case noMicrophone
    case micDenied
    case screenCaptureDenied
    case micSetupFailed
    case notRecording
    case noSessionDir
    case exportFailed
    case missingUITestFixture
    case unavailableOutputDevice
    case failedToMonitorOutputDevice
    case invalidAudioFormat
    case failedToCreateAudioInput
    case failedToStartWriter
    case failedToAppendAudio
    case failedToFinalizeSegment
    case finishAlreadyRequested

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found for audio capture"
        case .noMicrophone: return "No microphone found"
        case .micDenied: return "Microphone access denied. Enable in System Settings > Privacy & Security > Microphone"
        case .screenCaptureDenied: return "Screen & system audio recording access is required. Enable Recappi Mini in System Settings > Privacy & Security > Screen & System Audio Recording"
        case .micSetupFailed: return "Couldn't set up microphone capture"
        case .notRecording: return "Not currently recording"
        case .noSessionDir: return "No session directory"
        case .exportFailed: return "Failed to merge audio sources"
        case .missingUITestFixture: return "UI test fixture audio is missing"
        case .unavailableOutputDevice: return "Couldn't read the current output device format"
        case .failedToMonitorOutputDevice: return "Couldn't monitor output device changes"
        case .invalidAudioFormat: return "Audio format information is unavailable"
        case .failedToCreateAudioInput: return "Couldn't create the audio writer input"
        case .failedToStartWriter: return "Couldn't start the audio writer"
        case .failedToAppendAudio: return "Couldn't append captured audio"
        case .failedToFinalizeSegment: return "Couldn't finalize the recorded audio segment"
        case .finishAlreadyRequested: return "Audio finishing is already in progress"
        }
    }
}
