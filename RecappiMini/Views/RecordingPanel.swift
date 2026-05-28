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
    @State private var latestDoneJobStatusByRecordingID: [String: RemoteJobStatus] = [:]
    @State private var pendingAutoStopRequest: AutoStopRecordingRequest?

    let onOpenFolder: (URL) -> Void
    let onOpenCloud: () -> Void
    let onOpenCloudRecording: @MainActor @Sendable (String) -> Void
    let onClosePanel: () -> Void
    let onTranscribeCloudRecording: @MainActor @Sendable (String, @escaping @MainActor @Sendable (TranscriptionJob) -> Void) -> Void
    let onCloudRecordingUpdated: @MainActor @Sendable (CloudRecording, TranscriptionJob?) -> Void
    let onCloudRecordingDeleted: @MainActor @Sendable (String) -> Void

    var body: some View {
        mainView
            .id(panelContentIdentity)
            .transition(panelContentTransition)
            .animation(DT.motionAware(.spring(response: 0.36, dampingFraction: 0.50, blendDuration: 0.03)), value: panelContentIdentity)
            .frame(
                width: DT.panelWidth - DT.panelPadding * 2,
                alignment: .topLeading
            )
            .frame(minHeight: Self.contentMinHeight(for: recorder.state), alignment: .topLeading)
            .padding(panelPadding)
            .frame(width: DT.panelWidth)
            // Height is intentionally intrinsic. `PillShellView` measures the
            // hosted SwiftUI content with AppKit fitting size and resizes the
            // transparent NSPanel around it; individual controls can keep
            // stable internal heights, but the panel shell should not guess a
            // fixed state height.
            .onReceive(recorder.$autoStopRequest.compactMap { $0 }) { request in
                withAnimation(DT.motionAware(DT.easeSpring(DT.Motion.elementPresence))) {
                    pendingAutoStopRequest = request
                }
            }
            .onChange(of: recorder.state) { _, state in
                guard state != .recording else { return }
                pendingAutoStopRequest = nil
            }
            .onAppear {
                AppDelegate.shared.registerOpenSettingsAction {
                    openSettings()
                }
            }
    }

    private var panelPadding: EdgeInsets {
        let p = DT.panelPadding
        return EdgeInsets(top: p, leading: p, bottom: p, trailing: p)
    }

    private var panelContentIdentity: String {
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
        .opacity.combined(with: .scale(scale: 0.94, anchor: .center))
    }

    /// Keep the active capture flow in one stable shell height. Without this,
    /// stopping a recording makes AppKit resize the NSPanel while SwiftUI swaps
    /// the inner state, which reads as a small panel jump.
    nonisolated static let activeCaptureContentMinHeight: CGFloat = 52

    nonisolated static func contentMinHeight(for state: RecorderState) -> CGFloat? {
        switch state {
        case .recording, .processing, .error:
            return activeCaptureContentMinHeight
        case .done:
            // `.done` is the post-capture toast — DoneState collapsed to
            // a single ~22pt row, and forcing the 52pt active-capture
            // height left a large empty strip below the content. Return
            // nil so PillShellView resizes the NSPanel to the intrinsic
            // SwiftUI fittingSize and the toast reads as a tight notification.
            return nil
        case .idle, .starting:
            return nil
        }
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
                autoStopRequest: pendingAutoStopRequest,
                onKeepRecording: {
                    recorder.clearAutoStopRequest()
                    withAnimation(DT.motionAware(DT.ease(DT.Motion.elementPresence))) {
                        pendingAutoStopRequest = nil
                    }
                },
                onConfirmAutoStop: {
                    recorder.clearAutoStopRequest()
                    pendingAutoStopRequest = nil
                    stopRecording()
                },
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
                canTranscribe: canTranscribe(result: r),
                cloudStatus: doneCloudStatus(result: r),
                onTranscribe: { transcribeAndShow(result: r) },
                onShow: { showInCloud(result: r) },
                onNew: { recorder.reset() }
            )
        case .error(let message):
            ErrorState(
                recorder: recorder,
                message: message,
                onShow: { if let dir = recorder.lastSessionDir { onOpenFolder(dir) } },
                onSettings: presentSettings,
                onOpenLogs: openLogsFolder,
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

    private func openLogsFolder() {
        DiagnosticsLog.event("diagnostics", "open_logs_folder source=error_state")
        onOpenFolder(DiagnosticsLog.logsDirectoryURL)
    }

    private func startRecording() {
        startRecording(kind: .manual)
    }

    private func startRecording(kind: RecordingStartKind) {
        DiagnosticsLog.event("recording-panel", "start.click kind=\(kind.rawValue)")
        recorder.setIncludesMicrophoneAudio(config.recordingIncludeMicrophoneAudio)

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
                DiagnosticsLog.error(
                    "recording-panel",
                    "start.failed kind=\(kind.rawValue) \(DiagnosticsLog.errorSummary(error))"
                )
                recorder.state = .error(message: NetworkErrorPresenter.userFacingMessage(for: error))
            }
        }
    }

    private func startSuggestedRecording() {
        startRecording(kind: .suggested)
    }

    private func stopRecording() {
        DiagnosticsLog.event("recording-panel", "stop.click")
        Task {
            do {
                let duration = recorder.elapsedSeconds
                let sessionDir = try await recorder.stopRecording()
                await processSession(sessionDir, duration: duration)
            } catch {
                DiagnosticsLog.error(
                    "recording-panel",
                    "stop.failed \(DiagnosticsLog.errorSummary(error))"
                )
                recorder.state = .error(message: NetworkErrorPresenter.userFacingMessage(for: error))
            }
        }
    }

    private func retryProcessing(_ message: String) {
        DiagnosticsLog.event("recording-panel", "retry_processing.click hasSession=\(recorder.lastSessionDir != nil)")
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

        if let placeholder = SessionProcessor.localRecordingPlaceholder(
            sessionDir: sessionDir,
            duration: duration,
            status: .uploading
        ) {
            onCloudRecordingUpdated(placeholder, nil)
        }

        do {
            let result = try await SessionProcessor.shared.process(
                sessionDir: sessionDir,
                duration: duration,
                startsTranscription: false,
                updatePhase: { phase in
                    guard visibleProcessingSessionID == sessionID else { return }
                    recorder.state = .processing(phase)
                },
                onCloudRecordingUpdated: { recording, job in
                    rememberLatestJobStatus(recording: recording, job: job)
                    onCloudRecordingUpdated(recording, job)
                },
                onCloudRecordingDeleted: onCloudRecordingDeleted
            )
            if visibleProcessingSessionID == sessionID {
                recorder.state = .done(result: result)
                visibleProcessingSessionID = nil
                if config.recordingAutoTranscribeAfterUpload {
                    transcribeAndShow(result: result)
                }
            } else {
                postBackgroundProcessingNotification(for: result)
            }
        } catch {
            DiagnosticsLog.error(
                "recording-panel",
                "process_session.failed visible=\(visibleProcessingSessionID == sessionID) \(DiagnosticsLog.errorSummary(error))"
            )
            if let placeholder = SessionProcessor.localFailedRecordingPlaceholder(
                sessionDir: sessionDir,
                duration: duration,
                error: error
            ) {
                let message = NetworkErrorPresenter.userFacingMessage(for: error)
                let job = TranscriptionJob.failedRecordingPlaceholder(
                    recordingID: placeholder.id,
                    error: message
                )
                rememberLatestJobStatus(recording: placeholder, job: job)
                onCloudRecordingUpdated(
                    placeholder,
                    job
                )
            }
            if visibleProcessingSessionID == sessionID {
                recorder.state = .error(message: NetworkErrorPresenter.userFacingMessage(for: error))
                visibleProcessingSessionID = nil
            } else {
                postBackgroundProcessingFailureNotification(message: NetworkErrorPresenter.userFacingMessage(for: error))
            }
        }
    }

    private func detachCurrentProcessingToBackground() {
        DiagnosticsLog.event("recording-panel", "detach_processing.click visibleSession=\(visibleProcessingSessionID != nil)")
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
        DiagnosticsLog.event("recording-panel", "discard.click")
        Task {
            AppDelegate.shared.suppressAutoPromptForCurrentRecordingSourceUntilInactive()
            await recorder.discardRecording()
        }
    }

    private func transcribeAndShow(result: RecordingResult) {
        guard let recordingID = cloudRecordingID(for: result) else {
            onOpenCloud()
            return
        }
        latestDoneJobStatusByRecordingID[recordingID] = .queued
        onTranscribeCloudRecording(recordingID) { job in
            latestDoneJobStatusByRecordingID[recordingID] = job.status
        }
    }

    private func showInCloud(result: RecordingResult) {
        guard let recordingID = cloudRecordingID(for: result) else {
            onOpenCloud()
            return
        }
        onOpenCloudRecording(recordingID)
    }

    private func canTranscribe(result: RecordingResult) -> Bool {
        let transcript = result.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return transcript.isEmpty &&
            cloudRecordingID(for: result) != nil &&
            !config.recordingAutoTranscribeAfterUpload &&
            doneCloudStatus(result: result) == .pending
    }

    private func doneCloudStatus(result: RecordingResult) -> DoneCloudStatus {
        let manifest = RecordingStore.loadRemoteManifest(in: result.folderURL)
        let recordingID = Self.cleanID(manifest?.recordingId)
        return DoneCloudStatus.resolve(
            cloudEnabled: config.cloudEnabled,
            autoTranscribeAfterUpload: config.recordingAutoTranscribeAfterUpload,
            manifest: manifest,
            latestJobStatus: recordingID.flatMap { latestDoneJobStatusByRecordingID[$0] },
            hasTranscript: hasTranscript(result)
        )
    }

    private func hasTranscript(_ result: RecordingResult) -> Bool {
        guard let transcript = result.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !transcript.isEmpty
    }

    private func cloudRecordingID(for result: RecordingResult) -> String? {
        Self.cleanID(RecordingStore.loadRemoteManifest(in: result.folderURL)?.recordingId)
    }

    private func rememberLatestJobStatus(recording: CloudRecording, job: TranscriptionJob?) {
        guard let job else { return }
        latestDoneJobStatusByRecordingID[recording.id] = job.status
    }

    private nonisolated static func cleanID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
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

private enum RecordingStartKind: String, Identifiable {
    case manual
    case suggested

    var id: String { rawValue }
}
