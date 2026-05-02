import AppKit
import Combine
import SwiftUI

/// First-launch walkthrough: brief feature intro → required system
/// permissions → cloud sign-in → done. Lives in its own NSWindow rather
/// than the floating panel so the user can give the flow their full
/// attention without dismissing it accidentally.
///
/// The view is intentionally self-contained: it owns no business state
/// beyond the current step and the live permission/auth snapshots it
/// reads from existing services. When the flow finishes (Done / Get started)
/// the view calls `onFinish`, which the host (`AppDelegate`) uses to
/// flip `OnboardingState.didComplete` and close the window.
struct OnboardingView: View {
    @ObservedObject var sessionStore: AuthSessionStore
    let onFinish: () -> Void

    // Restore the last step the user was on so a detour through System
    // Settings (which often triggers an app relaunch when a permission
    // is granted) doesn't bounce the user back to the Welcome page.
    @State private var step: OnboardingStep = OnboardingState.lastStep
    @State private var permissionState = CapturePermissionSnapshot.placeholder
    @StateObject private var permissionPoller = PermissionPoller()

    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 16)

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial)
        }
        .frame(width: 540, height: 440)
        .background(
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.10, blue: 0.12), Color(red: 0.05, green: 0.06, blue: 0.07)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .onAppear { permissionState = CapturePermissionPrimer.shared.snapshot() }
        .onReceive(permissionPoller.$tick) { _ in
            permissionState = CapturePermissionPrimer.shared.snapshot()
        }
        .onChange(of: sessionStore.authStatus) { _, status in
            if case .signedIn = status, step == .signIn {
                advance(to: .done)
            }
        }
        .accessibilityIdentifier(AccessibilityIDs.Onboarding.window)
    }

    /// Centralized step transition: persists the new step to
    /// `OnboardingState.lastStep` so the user resumes here on relaunch
    /// (e.g. after macOS terminates the app to apply Screen Recording
    /// permissions). All in-view step changes funnel through this method
    /// rather than mutating `step` directly.
    ///
    /// The mutation runs inside `withAnimation` so the
    /// `.transition(.asymmetric(...))` on `stepContent` actually fires.
    /// We pick a short `easeInOut` so forward/back navigation feels
    /// snappy rather than a full carousel slide — the goal is "page
    /// changed" feedback, not a marketing flourish.
    private func advance(to next: OnboardingStep) {
        guard next != step else { return }
        let isForward = next.rawValue > step.rawValue
        transitionDirection = isForward ? .forward : .backward
        withAnimation(.easeInOut(duration: 0.22)) {
            step = next
        }
        OnboardingState.lastStep = next
    }

    /// Drives the asymmetric transition: forward steps slide in from the
    /// right, backward steps from the left. Using a stored direction
    /// rather than deriving it inside `.transition` avoids the
    /// SwiftUI quirk where the transition closure captures the *current*
    /// step at view-build time and not at the moment of mutation.
    @State private var transitionDirection: TransitionDirection = .forward
    private enum TransitionDirection { case forward, backward }

    private var stepInsertionTransition: AnyTransition {
        let dx: CGFloat = 16
        switch transitionDirection {
        case .forward:
            return .asymmetric(
                insertion: .opacity.combined(with: .offset(x: dx)),
                removal: .opacity.combined(with: .offset(x: -dx))
            )
        case .backward:
            return .asymmetric(
                insertion: .opacity.combined(with: .offset(x: -dx)),
                removal: .opacity.combined(with: .offset(x: dx))
            )
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        // `.id(step)` makes SwiftUI treat each step as a distinct view
        // identity, which is what allows the `.transition` to fire on
        // step changes. Without the id, SwiftUI would diff inside the
        // shared container and the modifier would never see an
        // insertion/removal pair to animate.
        Group {
            switch step {
            case .welcome: welcomeStep
            case .permissions: permissionsStep
            case .signIn: signInStep
            case .done: doneStep
            }
        }
        .id(step)
        .transition(stepInsertionTransition)
    }

    private var welcomeStep: some View {
        // All onboarding steps use the same vertical centering rule so
        // moving forward feels like a single layout breathing rather
        // than each page picking its own anchor. Concrete content can
        // grow taller (Permissions has the longest body) without us
        // re-tuning each step's frame — `.center` lets the layout
        // engine handle it.
        VStack(spacing: 18) {
            LogoTile(size: 72)
            Text("Welcome to Recappi Mini")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.dtLabel)
            VStack(alignment: .leading, spacing: 10) {
                bullet("Record any app's audio with one click", systemImage: "waveform")
                bullet("Auto-transcribe and summarize meetings", systemImage: "doc.text.magnifyingglass")
                bullet("Sync recordings across your devices", systemImage: "icloud")
            }
            .frame(maxWidth: 380)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Grant access")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.dtLabel)
            Text("Recappi needs two macOS permissions to capture audio. You can revoke them any time from System Settings.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.dtLabelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionRow(
                title: "Microphone",
                detail: "Captures your voice for narration and meetings.",
                state: permissionState.microphone,
                identifier: AccessibilityIDs.Onboarding.permissionMicrophone
            ) {
                Task {
                    let resolved = await CapturePermissionPrimer.shared.requestMicrophoneAccess()
                    permissionState = CapturePermissionSnapshot(
                        microphone: resolved,
                        screenCapture: permissionState.screenCapture
                    )
                }
            }

            permissionRow(
                title: "Screen & system audio recording",
                detail: "Captures the audio coming from other apps (browser, Zoom, etc.).",
                state: permissionState.screenCapture,
                identifier: AccessibilityIDs.Onboarding.permissionScreenCapture
            ) {
                let resolved = CapturePermissionPrimer.shared.requestScreenCaptureAccess()
                permissionState = CapturePermissionSnapshot(
                    microphone: permissionState.microphone,
                    screenCapture: resolved
                )
                if resolved == .needsAccess {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }
        // Match Welcome/SignIn/Done: every step uses `.center` so moving
        // between them keeps a stable visual baseline.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var signInStep: some View {
        VStack(spacing: 18) {
            // Match Welcome's `LogoTile(size: 72)` so the brand presence
            // is consistent across the two pre-completion steps. Done
            // intentionally uses the checkmark seal as a different
            // visual register (terminal acknowledgement, not branding).
            LogoTile(size: 72)
            Text("Sign in to Recappi Cloud")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.dtLabel)
            Text("Cloud keeps your transcripts, summaries, and audio across devices. You can also skip and sign in later.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.dtLabelSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Task {
                        do {
                            _ = try await sessionStore.startOAuth(
                                provider: .google,
                                origin: AppConfig.shared.effectiveBackendBaseURL
                            )
                        } catch {
                            // Auth errors land in `sessionStore.authStatusDetail`;
                            // no extra toast needed in onboarding.
                        }
                    }
                } label: {
                    onboardingAuthLabel(for: .google)
                }
                .buttonStyle(PanelPushButtonStyle(primary: true))
                .disabled(sessionStore.isAuthBusy)
                .frame(width: 180)
                .accessibilityIdentifier(AccessibilityIDs.Onboarding.signInGoogle)

                Button {
                    Task {
                        do {
                            _ = try await sessionStore.startOAuth(
                                provider: .github,
                                origin: AppConfig.shared.effectiveBackendBaseURL
                            )
                        } catch {
                            // see comment above
                        }
                    }
                } label: {
                    onboardingAuthLabel(for: .github)
                }
                .buttonStyle(PanelPushButtonStyle())
                .disabled(sessionStore.isAuthBusy)
                .frame(width: 180)
                .accessibilityIdentifier(AccessibilityIDs.Onboarding.signInGitHub)
            }
        }
        // Match Welcome/Permissions/Done.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var doneStep: some View {
        // Same `.center` as the other steps — peng-xiao wanted a single
        // alignment rule across all four steps, not an optical-anchor
        // special case for Done.
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(DT.statusReady)
            Text("You're all set")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.dtLabel)
            Text("Open the menu bar icon to start recording or browse Cloud.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.dtLabelSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Footer

    /// Three-column footer: leading 160pt (Back), center flex (step
    /// dots), trailing 160pt (Continue / next-step variant). Fixed
    /// outer column widths keep the indicator centered regardless of how
    /// the labels wrap and stop the buttons from sliding around as the
    /// content step changes.
    private var footer: some View {
        HStack(spacing: 8) {
            // Leading column: Back is available everywhere there is a
            // previous step (so Done can return to Sign In — Done is the
            // last onboarding step, not an irreversible success page).
            // The native title-bar close button is the escape hatch, so
            // the footer stays focused on flow navigation only.
            HStack(spacing: 8) {
                if let previous = previousStep {
                    Button {
                        advance(to: previous)
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.dtLabelSecondary)
                    .accessibilityIdentifier(AccessibilityIDs.Onboarding.backButton)
                }
            }
            .frame(width: 160, alignment: .leading)

            Spacer(minLength: 0)

            stepIndicator

            Spacer(minLength: 0)

            primaryButton
                .frame(width: 160, alignment: .trailing)
                .accessibilityIdentifier(AccessibilityIDs.Onboarding.primaryButton)
        }
    }

    /// Step that the leading "Back" button should return to, or `nil` if
    /// the user is already at the first step.
    ///
    /// `Done` is **not** a terminal navigation dead-end — only the
    /// `Get started` tap actually marks the flow as complete. Until the
    /// user commits to that, Back from `Done` returns to `Sign In` so
    /// they can change their mind (e.g. choose a different OAuth
    /// provider, or sign in if they originally skipped).
    private var previousStep: OnboardingStep? {
        switch step {
        case .welcome: return nil
        case .permissions: return .welcome
        case .signIn: return .permissions
        case .done: return .signIn
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { dot in
                Circle()
                    .fill(dot == step ? DT.waveformLit : Color.white.opacity(0.18))
                    .frame(width: 6, height: 6)
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .welcome:
            Button("Continue") { advance(to: .permissions) }
                .buttonStyle(PanelPushButtonStyle(primary: true))
                .frame(maxWidth: 140)
        case .permissions:
            // Allow Continue regardless of grant state — explicit gating
            // would trap users who momentarily denied a permission and
            // forces them back to System Settings before they can
            // sign-in. The permission rows already display the live
            // status, which is enough surface area to communicate "this
            // still needs to be granted".
            Button("Continue") {
                if case .signedIn = sessionStore.authStatus {
                    advance(to: .done)
                } else {
                    advance(to: .signIn)
                }
            }
            .buttonStyle(PanelPushButtonStyle(primary: true))
            .frame(maxWidth: 140)
        case .signIn:
            Button("I'll do this later") { advance(to: .done) }
                .buttonStyle(PanelPushButtonStyle())
                .frame(maxWidth: 160)
        case .done:
            Button("Get started") { complete() }
                .buttonStyle(PanelPushButtonStyle(primary: true))
                .frame(maxWidth: 160)
        }
    }

    /// Final completion: explicit "Get started" tap. Persists the
    /// terminal step + completion flag so the user is never re-prompted.
    private func complete() {
        OnboardingState.lastStep = .done
        OnboardingState.didComplete = true
        onFinish()
    }

    // MARK: - Building blocks

    private func bullet(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DT.waveformLit)
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.dtLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        state: CapturePermissionSnapshot.State,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: state.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(state == .authorized ? DT.statusReady : DT.systemOrange)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.dtLabel)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if state == .authorized {
                Text("Allowed")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DT.statusReady)
            } else {
                Button("Open Settings", action: action)
                    .buttonStyle(PanelPushButtonStyle())
                    .accessibilityIdentifier(identifier)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func onboardingAuthLabel(for provider: OAuthProvider) -> some View {
        if sessionStore.authFlowPhase?.activeProvider == provider {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                Text(sessionStore.authFlowPhase?.buttonLabel ?? "Connecting…")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
        } else {
            // Pair the brand logo (Google G / GitHub mark) with the
            // text label so the OAuth buttons match what users expect
            // from any modern sign-in surface — the previous text-only
            // version felt blank next to the brand-aware Welcome /
            // Done pages and made the SignIn step look unfinished.
            HStack(spacing: 7) {
                Image(nsImage: provider.logoImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                Text("Sign in with \(provider.displayName)")
                    .lineLimit(1)
            }
        }
    }
}

/// Polls the live TCC state every second while the onboarding window is
/// visible. macOS does not deliver a callback when the user toggles a
/// permission in System Settings, so we sniff the snapshot. Cheap: two
/// `AVCaptureDevice.authorizationStatus` calls + one Quartz preflight.
@MainActor
final class PermissionPoller: ObservableObject {
    @Published var tick: Int = 0
    private let timer: DispatchSourceTimer

    init() {
        let queue = DispatchQueue.main
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1.0, repeating: 1.0)
        self.timer = source
        source.setEventHandler { [weak self] in
            self?.tick &+= 1
        }
        source.resume()
    }

    // The `DispatchSourceTimer` is Sendable, so this nonisolated deinit
    // can safely cancel it without crossing a main-actor boundary.
    deinit {
        timer.cancel()
    }
}
