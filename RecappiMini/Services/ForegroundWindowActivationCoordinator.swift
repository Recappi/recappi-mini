import AppKit

@MainActor
final class ForegroundWindowActivationCoordinator {
    private let managedWindows: ManagedWindowRegistry
    private var foregroundWindowDemandCount = 0
    private var settingsSceneForegroundDemandActive = false

    init(managedWindows: ManagedWindowRegistry) {
        self.managedWindows = managedWindows
    }

    func preparePresentation() {
        foregroundWindowDemandCount += 1
        activatePresentation()
    }

    func prepareSettingsScenePresentation() {
        if !settingsSceneForegroundDemandActive {
            foregroundWindowDemandCount += 1
            settingsSceneForegroundDemandActive = true
        }
        activatePresentation()
    }

    func releaseSettingsSceneDemand() {
        guard settingsSceneForegroundDemandActive else {
            restoreAccessoryPolicyIfPossible()
            return
        }
        settingsSceneForegroundDemandActive = false
        releaseDemand()
    }

    func releaseDemand() {
        foregroundWindowDemandCount = max(0, foregroundWindowDemandCount - 1)
        restoreAccessoryPolicyIfPossible()
    }

    func activatePresentation() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
    }

    func restoreAccessoryPolicyIfPossible() {
        guard foregroundWindowDemandCount == 0 else { return }
        guard !managedWindows.hasVisibleForegroundWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
