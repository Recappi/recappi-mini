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
                recordingView
            }
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: showSettings) {
            resizeWindow()
        }
    }

    private func resizeWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let window = NSApp.windows.first(where: { $0 is FloatingPanel }) as? FloatingPanel else { return }
            let targetHeight: CGFloat = showSettings ? 180 : 80
            FloatingPanelController.resize(window, height: targetHeight)
        }
    }

    @ViewBuilder
    private var recordingView: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 10) {
                switch recorder.state {
                case .idle:
                    idleView
                case .recording:
                    recordingStateView
                case .stopping, .transcribing, .summarizing:
                    processingView
                case .done(let folderURL):
                    doneView(folderURL: folderURL)
                case .error(let message):
                    errorView(message: message)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // App selector (only in idle state)
            if case .idle = recorder.state, !recorder.detectedApps.isEmpty {
                Divider().padding(.horizontal, 10)
                appSelectorRow
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - State Views

    private var idleView: some View {
        Group {
            Text("Recappi Mini")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Spacer()
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Button(action: { startRecording() }) {
                HStack(spacing: 4) {
                    Image(systemName: "record.circle")
                    Text("Start")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.red.opacity(0.15))
                .foregroundStyle(.red)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var recordingStateView: some View {
        Group {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .modifier(PulsingModifier())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("REC")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.red)
                    Text(formatTime(recorder.elapsedSeconds))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                if let appName = recorder.recordingAppName {
                    Text(appName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: { stopRecording() }) {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                    Text("Stop")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.secondary.opacity(0.15))
                .foregroundStyle(.primary)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var processingView: some View {
        Group {
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
            Text(processingLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func doneView(folderURL: URL) -> some View {
        Group {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16))
            Text("Done")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Spacer()
            Button(action: { onOpenFolder(folderURL) }) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text("Open")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.blue.opacity(0.15))
                .foregroundStyle(.blue)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func errorView(message: String) -> some View {
        Group {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
    }

    // MARK: - App Selector

    private var appSelectorRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "app.badge.checkmark")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if recorder.detectedApps.count == 1, let app = recorder.detectedApps.first {
                Text(app.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
            } else {
                Picker("", selection: Binding(
                    get: { recorder.selectedApp?.id ?? "" },
                    set: { id in
                        recorder.selectedApp = recorder.detectedApps.first { $0.id == id }
                    }
                )) {
                    Text("All system audio").tag("")
                    ForEach(recorder.detectedApps) { app in
                        Text(app.name).tag(app.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            Button(action: {
                Task { await recorder.refreshApps() }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
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
                // print("[RecappiMini] Starting recording...")
                try await recorder.startRecording()
                // print("[RecappiMini] Recording started successfully")
            } catch {
                // print("[RecappiMini] Start recording error: \(error)")
                await MainActor.run {
                    recorder.state = .error(message: error.localizedDescription)
                }
                try? await Task.sleep(for: .seconds(5))
                await MainActor.run { recorder.reset() }
            }
        }
    }

    private func stopRecording() {
        Task {
            do {
                // print("[RecappiMini] Stopping recording...")
                let sessionDir = try await recorder.stopRecording()
                // print("[RecappiMini] Recording saved to: \(sessionDir.path)")

                let config = AppConfig.shared
                let transcriber = createTranscriber(config: config)

                // Transcribe
                await MainActor.run { recorder.state = .transcribing }
                let audioURL = RecordingStore.audioFileURL(in: sessionDir)
                let transcript = try await transcriber.transcribe(audioURL: audioURL)
                try RecordingStore.saveTranscript(transcript, in: sessionDir)

                // Summarize (only if LLM configured)
                if config.selectedProvider != .none {
                    await MainActor.run { recorder.state = .summarizing }
                    let summarizer = createSummarizer(config: config)
                    let summary = try await summarizer.summarize(transcript: transcript)
                    if !summary.isEmpty {
                        try RecordingStore.saveSummary(summary, in: sessionDir)
                    }
                }

                await MainActor.run {
                    recorder.state = .done(folderURL: sessionDir)
                }

                try? await Task.sleep(for: .seconds(10))
                await MainActor.run { recorder.reset() }

            } catch {
                // print("[RecappiMini] Stop/transcribe error: \(error)")
                await MainActor.run {
                    recorder.state = .error(message: error.localizedDescription)
                }
                try? await Task.sleep(for: .seconds(5))
                await MainActor.run { recorder.reset() }
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

struct PulsingModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
