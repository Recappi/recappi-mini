import SwiftUI

struct RecordingPanel: View {
    @ObservedObject var recorder: AudioRecorder
    @State private var showSettings = false

    let onOpenFolder: (URL) -> Void

    var body: some View {
        ZStack {
            if showSettings {
                SettingsView(isPresented: $showSettings)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            } else {
                mainView
                    .transition(.opacity)
            }
        }
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(GlassBackgroundModifier())
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showSettings)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: stateKey)
        .onChange(of: showSettings) { resizeToTarget() }
        .onChange(of: stateKey) { resizeToTarget() }
    }

    // MARK: - Main content switch

    @ViewBuilder
    private var mainView: some View {
        Group {
            switch recorder.state {
            case .idle:
                idleContent
            case .recording:
                recordingContent
            case .stopping, .transcribing, .summarizing:
                processingContent
            case .done(let result):
                doneContent(result: result)
            case .error(let message):
                errorContent(message: message)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Idle

    private var idleContent: some View {
        HStack(spacing: 8) {
            // App selector with inline icon
            HStack(spacing: 6) {
                if let app = recorder.selectedApp, let icon = app.icon {
                    Image(nsImage: icon)
                        .interpolation(.high)
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }

                Picker(selection: Binding(
                    get: { recorder.selectedApp?.id ?? "__all__" },
                    set: { id in
                        recorder.selectedApp = id == "__all__" ? nil : recorder.runningApps.first { $0.id == id }
                    }
                )) {
                    Text("All system audio").tag("__all__")
                    Divider()
                    ForEach(recorder.runningApps) { app in
                        Text(app.name).tag(app.id)
                    }
                } label: { EmptyView() }
                .pickerStyle(.menu)
                .fixedSize()
            }

            Spacer(minLength: 0)

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Settings")

            Button(action: { startRecording() }) {
                ZStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 22, height: 22)
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                }
            }
            .buttonStyle(.plain)
            .help("Start recording")
            .keyboardShortcut(.return, modifiers: [])
        }
        .task {
            await recorder.refreshApps()
        }
    }

    // MARK: - Recording

    private var recordingContent: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
                .modifier(PulsingModifier())

            VStack(alignment: .leading, spacing: 0) {
                Text(formatTime(recorder.elapsedSeconds))
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    if let app = recorder.selectedApp, let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 10, height: 10)
                    }
                    Text(recorder.recordingAppName ?? "All system audio")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button(action: { stopRecording() }) {
                ZStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 26, height: 26)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white)
                        .frame(width: 10, height: 10)
                }
            }
            .buttonStyle(.plain)
            .help("Stop recording")
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    // MARK: - Processing

    private var processingContent: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
            Text(processingLabel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Done

    private func doneContent(result: RecordingResult) -> some View {
        let preview = donePreview(result: result)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
                Text("Recording saved")
                    .font(.system(size: 12, weight: .medium))
                Text(formatTime(result.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: { onOpenFolder(result.folderURL) }) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Open folder")
                Button(action: { recorder.reset() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            if let preview {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    Text(preview.body)
                        .font(.system(size: 11))
                        .foregroundStyle(preview.isSummary ? .primary : .secondary)
                        .lineLimit(preview.isSummary ? 5 : 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private struct DonePreview {
        let label: String
        let body: String
        let isSummary: Bool
    }

    private func donePreview(result: RecordingResult) -> DonePreview? {
        if let s = result.summary, !s.isEmpty {
            return DonePreview(label: "Summary", body: s, isSummary: true)
        }
        if let t = result.transcript, !t.isEmpty {
            return DonePreview(label: "Transcript", body: t, isSummary: false)
        }
        return nil
    }

    // MARK: - Error

    private func errorContent(message: String) -> some View {
        let recoverable = recorder.lastSessionDir != nil
        let configIssue = isConfigRelated(message)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 14))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: { recorder.reset() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            HStack(spacing: 8) {
                if recoverable {
                    Button(action: { retryProcessing() }) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Re-run transcription on the saved audio")

                    if let dir = recorder.lastSessionDir {
                        Button(action: { onOpenFolder(dir) }) {
                            Label("Open folder", systemImage: "folder")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.blue)
                    }
                }

                if configIssue {
                    Button(action: { showSettings = true }) {
                        Label("Settings", systemImage: "gearshape")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Open settings — check API key or language")
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func isConfigRelated(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("api")
            || lower.contains("key")
            || lower.contains("author")
            || lower.contains("language not supported")
    }

    // MARK: - Height / resize

    private var stateKey: String {
        if showSettings { return "settings" }
        switch recorder.state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .stopping, .transcribing, .summarizing: return "processing"
        case .done(let r):
            if let s = r.summary, !s.isEmpty { return "done-summary" }
            return (r.transcript ?? "").isEmpty ? "done-short" : "done-transcript"
        case .error(let msg): return errorHasActions(msg) ? "error-actions" : "error-short"
        }
    }

    private var targetHeight: CGFloat {
        if showSettings { return 200 }
        switch recorder.state {
        case .idle: return 56
        case .recording: return 72
        case .stopping, .transcribing, .summarizing: return 52
        case .done(let r):
            if let s = r.summary, !s.isEmpty { return 140 }
            return (r.transcript ?? "").isEmpty ? 52 : 110
        case .error(let msg): return errorHasActions(msg) ? 96 : 56
        }
    }

    private func errorHasActions(_ message: String) -> Bool {
        recorder.lastSessionDir != nil || isConfigRelated(message)
    }

    private func resizeToTarget() {
        guard let window = NSApp.windows.first(where: { $0 is FloatingPanel }) as? FloatingPanel else { return }
        FloatingPanelController.resize(window, height: targetHeight)
    }

    // MARK: - Helpers

    private var processingLabel: String {
        switch recorder.state {
        case .stopping: return "Saving..."
        case .transcribing: return "Transcribing..."
        case .summarizing: return "Summarizing..."
        default: return "Processing..."
        }
    }

    private func startRecording() {
        Task {
            do {
                try await recorder.startRecording()
            } catch {
                recorder.state = .error(message: error.localizedDescription)
            }
        }
    }

    private func stopRecording() {
        Task {
            do {
                let duration = recorder.elapsedSeconds
                let sessionDir = try await recorder.stopRecording()
                await processAudio(sessionDir: sessionDir, duration: duration)
            } catch {
                recorder.state = .error(message: error.localizedDescription)
            }
        }
    }

    private func retryProcessing() {
        guard let dir = recorder.lastSessionDir else { return }
        let duration = recorder.lastDuration
        Task { await processAudio(sessionDir: dir, duration: duration) }
    }

    private func processAudio(sessionDir: URL, duration: Int) async {
        do {
            let config = AppConfig.shared
            let transcriber = createTranscriber(config: config)

            recorder.state = .transcribing
            let audioURL = RecordingStore.audioFileURL(in: sessionDir)
            let transcript = try await transcriber.transcribe(audioURL: audioURL)
            try RecordingStore.saveTranscript(transcript, in: sessionDir)

            var summary: String? = nil
            if config.selectedProvider != .none {
                recorder.state = .summarizing
                let summarizer = createSummarizer(config: config)
                let s = try await summarizer.summarize(transcript: transcript)
                if !s.isEmpty {
                    try RecordingStore.saveSummary(s, in: sessionDir)
                    summary = s
                }
            }

            recorder.state = .done(result: RecordingResult(
                folderURL: sessionDir,
                transcript: transcript,
                summary: summary,
                duration: duration
            ))
        } catch {
            recorder.state = .error(message: error.localizedDescription)
        }
    }

    private func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

struct GlassBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        } else {
            content
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
    }
}

struct PulsingModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
