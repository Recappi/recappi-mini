import Foundation

enum AccessibilityIDs {
    enum Settings {
        static let authStatus = "recappi.settings.authStatus"
        static let authStatusText = "recappi.settings.authStatusText"
        static let cloudToggle = "recappi.settings.cloudToggle"
        static let signInGoogleButton = "recappi.settings.signInGoogleButton"
        static let signInGitHubButton = "recappi.settings.signInGitHubButton"
        static let reconnectButton = "recappi.settings.reconnectButton"
        static let signOutButton = "recappi.settings.signOutButton"
        static let permissionMicrophoneStatus = "recappi.settings.permissionMicrophoneStatus"
        static let permissionScreenCaptureStatus = "recappi.settings.permissionScreenCaptureStatus"
        static let requestMicrophoneButton = "recappi.settings.requestMicrophoneButton"
        static let requestScreenCaptureButton = "recappi.settings.requestScreenCaptureButton"
        static let refreshPermissionsButton = "recappi.settings.refreshPermissionsButton"
    }

    enum Panel {
        static let recordButton = "recappi.panel.recordButton"
        static let stopButton = "recappi.panel.stopButton"
        static let discardButton = "recappi.panel.discardButton"
        static let waveformToggle = "recappi.panel.waveformToggle"
        static let processingTitle = "recappi.panel.processingTitle"
        static let processingDetail = "recappi.panel.processingDetail"
        static let doneTitle = "recappi.panel.doneTitle"
        static let errorTitle = "recappi.panel.errorTitle"
        static let retryButton = "recappi.panel.retryButton"
        static let settingsButton = "recappi.panel.settingsButton"
        static let showButton = "recappi.panel.showButton"
    }
}
