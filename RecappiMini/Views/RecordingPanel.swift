import AppKit
import SwiftUI
@preconcurrency import UserNotifications

// MARK: - Top-level panel

struct RecordingPanel: View {
    @ObservedObject var recorder: AudioRecorder
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var config = AppConfig.shared
    @State private var visibleProcessingSessionID: UUID?
    @State private var detachProcessingWhenReady = false
    @State private var preflightStartKind: RecordingPreflightStartKind?
    @State private var preflightShowsTranslation = AppConfig.shared.liveCaptionsBilingualEnabled
    @State private var preflightTargetLanguage = AppConfig.shared.liveCaptionsTranslationTargetLanguage

    let onOpenFolder: (URL) -> Void
    let onOpenCloud: () -> Void
    let onClosePanel: () -> Void
    let onCloudRecordingUpdated: @MainActor @Sendable (CloudRecording, TranscriptionJob?) -> Void
    let onCloudRecordingDeleted: @MainActor @Sendable (String) -> Void

    var body: some View {
        mainView
            .id(panelContentIdentity)
            .transition(panelContentTransition)
            .animation(DT.easeSpring(DT.Motion.contentSwap), value: panelContentIdentity)
            .frame(
                width: DT.panelWidth - DT.panelPadding * 2,
                alignment: .topLeading
            )
            .padding(panelPadding)
            .frame(width: DT.panelWidth)
            // Height is intentionally intrinsic. `PillShellView` measures the
            // hosted SwiftUI content with AppKit fitting size and resizes the
            // transparent NSPanel around it; individual controls can keep
            // stable internal heights, but the panel shell should not guess a
            // fixed state height.
            .onReceive(recorder.$autoStopRequest.compactMap { $0 }) { _ in
                stopRecording()
            }
    }

    private var panelPadding: EdgeInsets {
        let p = DT.panelPadding
        return EdgeInsets(top: p, leading: p, bottom: p, trailing: p)
    }

    private var panelContentIdentity: String {
        if preflightStartKind != nil {
            return "preflight"
        }
        switch recorder.state {
        case .idle:
            return "idle"
        case .starting:
            return "starting"
        case .recording:
            return "recording"
        case .processing:
            return "processing"
        case .done:
            return "done"
        case .error:
            return "error"
        }
    }

    private var panelContentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .bottom)),
            removal: .opacity
        )
    }

    @ViewBuilder
    private var mainView: some View {
        if let preflightStartKind {
            RecordingPreflightSheet(
                showsTranslation: $preflightShowsTranslation,
                targetLanguage: $preflightTargetLanguage,
                backendRealtimeEnabled: config.backendRealtimeLiveCaptionsEnabled,
                onCancel: { self.preflightStartKind = nil },
                onStart: { startRecordingAfterPreflight(preflightStartKind) }
            )
        } else {
            switch recorder.state {
            case .idle:
                IdleState(
                    recorder: recorder,
                    isStarting: false,
                    onCloud: onOpenCloud,
                    onRecord: startRecording,
                    onRecordSuggestion: startSuggestedRecording,
                    onClose: onClosePanel
                )
            case .starting:
                IdleState(
                    recorder: recorder,
                    isStarting: true,
                    onCloud: onOpenCloud,
                    onRecord: startRecording,
                    onRecordSuggestion: startSuggestedRecording,
                    onClose: onClosePanel
                )
            case .recording:
                RecordingState(
                    recorder: recorder,
                    onDiscard: discardRecording,
                    onStop: stopRecording,
                    onClose: onClosePanel
                )
            case .processing(let phase):
                ProcessingState(
                    phase: phase,
                    onClose: detachCurrentProcessingToBackground
                )
            case .done(let r):
                DoneState(
                    result: r,
                    onShow: onOpenCloud,
                    onCopy: { copyTranscript(r) },
                    onNew: { recorder.reset() }
                )
            case .error(let message):
                ErrorState(
                    recorder: recorder,
                    message: message,
                    onShow: { if let dir = recorder.lastSessionDir { onOpenFolder(dir) } },
                    onSettings: presentSettings,
                    onRetry: { retryProcessing(message) },
                    onDismiss: { recorder.reset() }
                )
            }
        }
    }

    // MARK: - Actions

    /// Flip activation policy so the Settings window comes to the foreground.
    /// AppDelegate releases that demand when the Settings window closes.
    private func presentSettings() {
        AppDelegate.shared.prepareForSettingsScenePresentation()
        openSettings()
    }

    private func startRecording() {
        preparePreflightDefaults()
        preflightStartKind = .manual
    }

    private func startRecordingAfterPreflight(_ kind: RecordingPreflightStartKind) {
        AppConfig.shared.liveCaptionsBilingualEnabled = preflightShowsTranslation
        AppConfig.shared.liveCaptionsTranslationTargetLanguage =
            LiveCaptionTranslationTargetLanguageOption.normalizedCode(preflightTargetLanguage)
        preflightStartKind = nil

        Task {
            do {
                if kind == .suggested {
                    guard recorder.acceptRecordingSuggestion() else { return }
                }
                NSLog("[Recappi] startRecording() calling AudioRecorder.startRecording()")
                try await recorder.startRecording()
                NSLog("[Recappi] startRecording() returned, state now = \(recorder.state)")
            } catch {
                NSLog("[Recappi] startRecording() error: \(error)")
                recorder.state = .error(message: NetworkErrorPresenter.userFacingMessage(for: error))
            }
        }
    }

    private func startSuggestedRecording() {
        preparePreflightDefaults()
        preflightStartKind = .suggested
    }

    private func preparePreflightDefaults() {
        preflightShowsTranslation = config.backendRealtimeLiveCaptionsEnabled
            && config.liveCaptionsBilingualEnabled
        preflightTargetLanguage = config.liveCaptionsTranslationTargetLanguage
    }

    private func stopRecording() {
        Task {
            do {
                let duration = recorder.elapsedSeconds
                let sessionDir = try await recorder.stopRecording()
                await processSession(sessionDir, duration: duration)
            } catch {
                recorder.state = .error(message: NetworkErrorPresenter.userFacingMessage(for: error))
            }
        }
    }

    private func retryProcessing(_ message: String) {
        guard let sessionDir = recorder.lastSessionDir else {
            recorder.state = .error(message: "No session to retry")
            return
        }
        Task { await processSession(sessionDir, duration: recorder.elapsedSeconds) }
    }

    private func processSession(_ sessionDir: URL, duration: Int) async {
        let sessionID = UUID()
        visibleProcessingSessionID = sessionID

        if detachProcessingWhenReady {
            detachProcessingWhenReady = false
            visibleProcessingSessionID = nil
            recorder.reset()
        }

        do {
            let result = try await SessionProcessor.shared.process(
                sessionDir: sessionDir,
                duration: duration,
                updatePhase: { phase in
                    guard visibleProcessingSessionID == sessionID else { return }
                    recorder.state = .processing(phase)
                },
                onCloudRecordingUpdated: onCloudRecordingUpdated,
                onCloudRecordingDeleted: onCloudRecordingDeleted
            )
            if visibleProcessingSessionID == sessionID {
                recorder.state = .done(result: result)
                visibleProcessingSessionID = nil
            } else {
                postBackgroundProcessingNotification(for: result)
            }
        } catch {
            if visibleProcessingSessionID == sessionID {
                recorder.state = .error(message: NetworkErrorPresenter.userFacingMessage(for: error))
                visibleProcessingSessionID = nil
            } else {
                postBackgroundProcessingFailureNotification(message: NetworkErrorPresenter.userFacingMessage(for: error))
            }
        }
    }

    private func detachCurrentProcessingToBackground() {
        if visibleProcessingSessionID == nil {
            detachProcessingWhenReady = true
        } else {
            visibleProcessingSessionID = nil
            recorder.reset()
        }
        requestBackgroundNotificationAuthorizationIfNeeded()
        onClosePanel()
    }

    private func discardRecording() {
        Task {
            _ = try? await recorder.stopRecording()
            recorder.reset()
        }
    }

    /// "Copy" in the done state copies the transcript text when available.
    private func copyTranscript(_ r: RecordingResult) {
        let body = r.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !body.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }

    private func postBackgroundProcessingNotification(for result: RecordingResult) {
        let transcript = (result.transcript ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let body = transcript.isEmpty
            ? "Your recording has been processed in the background."
            : String(transcript.prefix(140))
        postBackgroundProcessingNotification(
            title: "Transcription complete",
            body: body,
            playSound: false
        )
    }

    private func postBackgroundProcessingFailureNotification(message: String) {
        postBackgroundProcessingNotification(
            title: "Processing failed",
            body: message,
            playSound: true
        )
    }

    private func requestBackgroundNotificationAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func postBackgroundProcessingNotification(title: String, body: String, playSound: Bool) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let post: @Sendable () -> Void = {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.threadIdentifier = "recappi.processing"
                content.userInfo = ["action": "showPanel"]
                if playSound {
                    content.sound = .default
                }
                let request = UNNotificationRequest(
                    identifier: "recappi.processing.\(UUID().uuidString)",
                    content: content,
                    trigger: nil
                )
                center.add(request)
            }

            switch settings.authorizationStatus {
            case .authorized, .provisional:
                post()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { post() }
                }
            default:
                break
            }
        }
    }

}

private enum RecordingPreflightStartKind: String, Identifiable {
    case manual
    case suggested

    var id: String { rawValue }
}

struct RecordingPreflightSheet: View {
    @Binding var showsTranslation: Bool
    @Binding var targetLanguage: String
    let backendRealtimeEnabled: Bool
    let onCancel: () -> Void
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Before recording")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.labelPrimary)
                Text("Choose the live caption display for this recording.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show translation", isOn: $showsTranslation)
                    .toggleStyle(.switch)
                    .disabled(!backendRealtimeEnabled)
                    .accessibilityIdentifier(AccessibilityIDs.Panel.preflightShowTranslationToggle)

                if showsTranslation {
                    Picker("Translate to", selection: normalizedTargetLanguageBinding) {
                        ForEach(LiveCaptionTranslationTargetLanguageOption.common) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!backendRealtimeEnabled)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityIdentifier(AccessibilityIDs.Panel.preflightTargetLanguagePicker)
                }

                if !backendRealtimeEnabled {
                    Text("Translation requires backend Realtime live captions in Settings.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.labelTertiary)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(DT.ease(DT.Motion.elementPresence), value: showsTranslation)
            .animation(DT.ease(DT.Motion.elementPresence), value: backendRealtimeEnabled)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityIDs.Panel.preflightCancelButton)
                Button("Start recording", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AccessibilityIDs.Panel.preflightStartButton)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIDs.Panel.preflightSheet)
    }

    private var normalizedTargetLanguageBinding: Binding<String> {
        Binding(
            get: { LiveCaptionTranslationTargetLanguageOption.normalizedCode(targetLanguage) },
            set: { targetLanguage = LiveCaptionTranslationTargetLanguageOption.normalizedCode($0) }
        )
    }
}
