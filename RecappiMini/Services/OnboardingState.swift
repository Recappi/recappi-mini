import Foundation

/// Tracks first-launch onboarding progress in `UserDefaults`. The model
/// is two pieces of state, intentionally no more:
///
/// 1. `didComplete: Bool` — set to `true` when the user reaches the
///    final "Get started" or closes the onboarding window with the
///    native title-bar close button.
///
/// 2. `lastStep: OnboardingStep` — the step the user last advanced to.
///    Persisted on every transition and consulted on next launch so a
///    detour through System Settings (granting microphone or screen
///    recording, which often triggers an app relaunch) does not bounce
///    the user back to the Welcome page.
///
/// Outside of those two flags the flow remains stateless: each step
/// queries live system state (`AVCaptureDevice.authorizationStatus`,
/// `CGPreflightScreenCaptureAccess`, `AuthSessionStore.authStatus`)
/// rather than caching its own progress, so a permission flipped in
/// System Settings is reflected immediately without us needing to
/// invalidate anything.
enum OnboardingState {
    private static let didCompleteKey = "recappi.onboarding.didComplete"
    private static let lastStepKey = "recappi.onboarding.lastStep"

    /// `true` once the user has either finished the flow (reached Done /
    /// Get started) or closed the onboarding window with the native
    /// title-bar close button. Resetting this key restarts the flow on
    /// next launch.
    static var didComplete: Bool {
        get { UserDefaults.standard.bool(forKey: didCompleteKey) }
        set { UserDefaults.standard.set(newValue, forKey: didCompleteKey) }
    }

    /// Last step the user has advanced to (or returned to). Defaults to
    /// `.welcome` if absent or unparseable. Persisted via raw value so
    /// future re-orderings of the enum cases stay backwards compatible.
    static var lastStep: OnboardingStep {
        get {
            let stored = UserDefaults.standard.integer(forKey: lastStepKey)
            return OnboardingStep(rawValue: stored) ?? .welcome
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: lastStepKey)
        }
    }

    /// Pure decision used by both `AppDelegate` and unit tests: should we
    /// present the onboarding window at the moment the app finishes
    /// launching?
    ///
    /// We currently gate on the persisted completion flag plus the two
    /// UI-test escape hatches. We do not, for example, reopen the flow
    /// when a permission is later revoked — that case shows up naturally
    /// in the existing `RecordingPanel` permission primer and the Cloud
    /// sign-in view. Onboarding is strictly a first-launch concept.
    static func shouldPresentOnLaunch(
        didComplete: Bool = OnboardingState.didComplete,
        uiTestModeForcesOnboarding: Bool = false,
        uiTestModeSuppressesOnboarding: Bool = false
    ) -> Bool {
        if uiTestModeSuppressesOnboarding { return false }
        if uiTestModeForcesOnboarding { return true }
        return !didComplete
    }
}

/// Identifiers for the onboarding flow's steps. `Int` raw values are
/// persisted in `UserDefaults` (see `OnboardingState.lastStep`); only
/// add new cases at the end and never recycle values, otherwise existing
/// users will resume at the wrong step after the upgrade.
enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case permissions = 1
    case signIn = 2
    case done = 3
}
