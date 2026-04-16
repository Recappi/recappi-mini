import SwiftUI

struct RecordingPanel: View {
    @ObservedObject var recorder: AudioRecorder
    @State private var showSettings = false

    let onOpenFolder: (URL) -> Void

    var body: some View {
        Group {
            if showSettings {
                SettingsView(isPresented: $showSettings)
            } else {
                mainView
            }
        }
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(GlassBackgroundModifier())
        .onChange(of: showSettings) {
            resizeWindow()
        }
    }

    private func resizeWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let window = NSApp.windows.first(where: { $0 is FloatingPanel }) as? FloatingPanel else { return }
            let targetHeight: CGFloat = showSettings ? 200 : 80
            FloatingPanelController.resize(window, height: targetHeight)
        }
    }

    // MARK: - Main View

    @ViewBuilder
    private var mainView: some View {
        VStack(spacing: 0) {
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
        .padding(12)
    }

    // MARK: - Idle

    private var idleContent: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Recappi")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                + Text(" Mini")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                // Selected app icon (outside Picker for proper sizing)
                if let app = recorder.selectedApp, let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                Picker("", selection: Binding(
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
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Spacer()

                Button(action: { Task { await recorder.refreshApps() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)

                Button(action: { startRecording() }) {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Recording

    private var recordingContent: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 6, height: 6)
                .modifier(PulsingModifier())

            if let app = recorder.selectedApp, let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
            }

            Text(recorder.recordingAppName ?? "All audio")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(formatTime(recorder.elapsedSeconds))
                .font(.system(size: 12, weight: .medium, design: .monospaced))

            Button(action: { stopRecording() }) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Processing

    private var processingContent: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)
                .frame(width: 16, height: 16)
            Text(processingLabel)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Done

    private func doneContent(result: RecordingResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
                Text("Recording saved")
                    .font(.system(size: 12, weight: .medium))
                Text("(\(formatTime(result.duration)))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { onOpenFolder(result.folderURL) }) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                Button(action: { recorder.reset() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            if let transcript = result.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Error

    private func errorContent(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button(action: { recorder.reset() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
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
                let config = AppConfig.shared
                let transcriber = createTranscriber(config: config)

                recorder.state = .transcribing
                let audioURL = RecordingStore.audioFileURL(in: sessionDir)
                let transcript = try await transcriber.transcribe(audioURL: audioURL)
                try RecordingStore.saveTranscript(transcript, in: sessionDir)

                if config.selectedProvider != .none {
                    recorder.state = .summarizing
                    let summarizer = createSummarizer(config: config)
                    let summary = try await summarizer.summarize(transcript: transcript)
                    if !summary.isEmpty {
                        try RecordingStore.saveSummary(summary, in: sessionDir)
                    }
                }

                recorder.state = .done(result: RecordingResult(
                    folderURL: sessionDir,
                    transcript: transcript,
                    duration: duration
                ))
            } catch {
                recorder.state = .error(message: error.localizedDescription)
            }
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
