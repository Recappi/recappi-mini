import AppKit
import SwiftUI
@preconcurrency import UserNotifications

// MARK: - Top-level panel

struct RecordingPanel: View {
    @ObservedObject var recorder: AudioRecorder
    @Environment(\.openSettings) private var openSettings
    @State private var visibleProcessingSessionID: UUID?
    @State private var detachProcessingWhenReady = false

    let onOpenFolder: (URL) -> Void
    let onOpenCloud: () -> Void
    let onClosePanel: () -> Void
    let onCloudRecordingUpdated: @MainActor @Sendable (CloudRecording, TranscriptionJob?) -> Void
    let onCloudRecordingDeleted: @MainActor @Sendable (String) -> Void

    var body: some View {
        mainView
            .frame(
                width: DT.panelWidth - DT.panelPadding * 2,
                height: contentHeight,
                alignment: .topLeading
            )
            .padding(panelPadding)
            .frame(width: DT.panelWidth, height: contentHeight + DT.panelPadding * 2)
            // Keep explicit per-state heights so the transparent NSPanel can
            // snap to the latest SwiftUI size without animating AppKit layout.
            // Do not clip here: the logo glow intentionally paints outside
            // its 28pt tile bounds, while the outer panel still clips to the
            // rounded pill shape.
            .onReceive(recorder.$autoStopRequest.compactMap { $0 }) { _ in
                stopRecording()
            }
    }

    private var panelPadding: EdgeInsets {
        let p = DT.panelPadding
        return EdgeInsets(top: p, leading: p, bottom: p, trailing: p)
    }

    private var contentHeight: CGFloat {
        switch recorder.state {
        case .idle, .starting:
            recorder.recordingSuggestion == nil && recorder.meetingPrompt == nil ? 28 : 48
        case .recording:
            48
        case .processing:
            50
        case .done(let result):
            doneContentHeight(for: result)
        case .error(let message):
            errorContentHeight(for: message)
        }
    }

    private func doneContentHeight(for _: RecordingResult) -> CGFloat {
        48
    }

    private func errorContentHeight(for message: String) -> CGFloat {
        let flattened = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let estimatedLines = max(1, min(2, Int(ceil(Double(flattened.count) / 44.0))))
        let headerHeight: CGFloat = estimatedLines == 1 ? 31 : 45
        let hasActions = recorder.lastSessionDir != nil || Self.isConfigRelatedError(message)
        return headerHeight + (hasActions ? 30 : 0)
    }

    private static func isConfigRelatedError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("api")
            || lower.contains("key")
            || lower.contains("auth")
            || lower.contains("oauth")
            || lower.contains("token")
            || lower.contains("bearer")
            || lower.contains("session")
            || lower.contains("sign in")
            || lower.contains("language not supported")
    }

    @ViewBuilder
    private var mainView: some View {
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
                onCloud: onOpenCloud,
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

    // MARK: - Actions

    /// Flip activation policy so the Settings window comes to the foreground.
    /// AppDelegate releases that demand when the Settings window closes.
    private func presentSettings() {
        AppDelegate.shared.prepareForSettingsScenePresentation()
        openSettings()
    }

    private func startRecording() {
        Task {
            do {
                NSLog("[Recappi] startRecording() calling AudioRecorder.startRecording()")
                try await recorder.startRecording()
                NSLog("[Recappi] startRecording() returned, state now = \(recorder.state)")
            } catch {
                NSLog("[Recappi] startRecording() error: \(error)")
                recorder.state = .error(message: error.localizedDescription)
            }
        }
    }

    private func startSuggestedRecording() {
        guard recorder.acceptRecordingSuggestion() else { return }
        startRecording()
    }

    private func stopRecording() {
        Task {
            do {
                let duration = recorder.elapsedSeconds
                let sessionDir = try await recorder.stopRecording()
                await processSession(sessionDir, duration: duration)
            } catch {
                recorder.state = .error(message: error.localizedDescription)
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
                recorder.state = .error(message: error.localizedDescription)
                visibleProcessingSessionID = nil
            } else {
                postBackgroundProcessingFailureNotification(message: error.localizedDescription)
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
