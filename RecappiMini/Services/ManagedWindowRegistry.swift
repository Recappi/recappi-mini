import AppKit

@MainActor
final class ManagedWindowRegistry {
    enum Route {
        case settings
        case cloud
        case liveCaptions
        case onboarding
        case about
    }

    var settingsWindow: NSWindow?
    var cloudWindow: NSWindow?
    var liveCaptionWindow: NSPanel?
    var onboardingWindow: NSWindow?
    var aboutWindow: NSWindow?

    func route(for window: NSWindow) -> Route? {
        if window === settingsWindow {
            return .settings
        }
        if window === cloudWindow {
            return .cloud
        }
        if window === liveCaptionWindow {
            return .liveCaptions
        }
        if window === onboardingWindow {
            return .onboarding
        }
        if window === aboutWindow {
            return .about
        }
        return nil
    }

    func clear(_ route: Route) {
        switch route {
        case .settings:
            settingsWindow = nil
        case .cloud:
            cloudWindow = nil
        case .liveCaptions:
            liveCaptionWindow = nil
        case .onboarding:
            onboardingWindow = nil
        case .about:
            aboutWindow = nil
        }
    }

    var hasVisibleForegroundWindow: Bool {
        hasVisibleSettingsWindow
            || cloudWindow?.isVisible == true
            || onboardingWindow?.isVisible == true
            || aboutWindow?.isVisible == true
    }

    private var hasVisibleSettingsWindow: Bool {
        settingsWindow?.isVisible == true || NSApp.windows.contains { window in
            window.isVisible && window.title.localizedCaseInsensitiveContains("settings")
        }
    }
}
