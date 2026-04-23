import AVFoundation
import CoreGraphics
import Foundation

struct CapturePermissionSnapshot: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case authorized
        case needsAccess

        var label: String {
            switch self {
            case .authorized:
                return "Allowed"
            case .needsAccess:
                return "Needs access"
            }
        }

        var systemImage: String {
            switch self {
            case .authorized:
                return "checkmark.circle.fill"
            case .needsAccess:
                return "exclamationmark.circle.fill"
            }
        }
    }

    let microphone: State
    let screenCapture: State

    static let placeholder = CapturePermissionSnapshot(
        microphone: .needsAccess,
        screenCapture: .needsAccess
    )
}

@MainActor
final class CapturePermissionPrimer {
    static let shared = CapturePermissionPrimer()

    private init() {}

    func snapshot() -> CapturePermissionSnapshot {
        CapturePermissionSnapshot(
            microphone: microphoneState(),
            screenCapture: screenCaptureState()
        )
    }

    func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestMicrophoneAccess() async -> CapturePermissionSnapshot.State {
        _ = await requestMicrophoneIfNeeded()
        return microphoneState()
    }

    func requestScreenCaptureAccess() -> CapturePermissionSnapshot.State {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        return screenCaptureState()
    }

    private func microphoneState() -> CapturePermissionSnapshot.State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .notDetermined, .denied, .restricted:
            return .needsAccess
        @unknown default:
            return .needsAccess
        }
    }

    private func screenCaptureState() -> CapturePermissionSnapshot.State {
        CGPreflightScreenCaptureAccess() ? .authorized : .needsAccess
    }

    @discardableResult
    private func requestMicrophoneIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

}
