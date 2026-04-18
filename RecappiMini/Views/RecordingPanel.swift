import AppKit
import SwiftUI

struct RecordingPanel: View {
    @ObservedObject var recorder: AudioRecorder
    @Environment(\.openSettings) private var openSettings

    let onOpenFolder: (URL) -> Void

    /// The app is LSUIElement + .accessory + nonactivatingPanel, so nothing
    /// in the panel's click chain promotes RecappiMini to the foreground.
    /// Without that, openSettings() opens behind whatever was frontmost and
    /// reads to the user as "the button did nothing." Switching activation
    /// policy temporarily makes the Settings window come to front like a
    /// regular app window.
    private func presentSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    var body: some View {
        mainView
            .frame(width: 280)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(GlassBackgroundModifier())
            .animation(.easeOut(duration: 0.2), value: stateKey)
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
            AudioSourceMenu(recorder: recorder)

            Spacer(minLength: 0)

            Button(action: { presentSettings() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")

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
        VStack(alignment: .leading, spacing: 8) {
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
            Spacer(minLength: 0)
            Button(action: { recorder.reset() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Height / resize

    private var stateKey: String {
        switch recorder.state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .stopping, .transcribing, .summarizing: return "processing"
        case .done(let r): return "done-\((r.transcript ?? "").isEmpty ? "short" : "long")"
        case .error: return "error"
        }
    }

    private var targetHeight: CGFloat {
        switch recorder.state {
        case .idle: return 56
        case .recording: return 72
        case .stopping, .transcribing, .summarizing: return 52
        case .done(let r): return (r.transcript ?? "").isEmpty ? 52 : 110
        case .error: return 52
        }
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

/// Audio source dropdown. Renders as a compact "label + chevron" affordance
/// that pops open a macOS menu with each app's icon inline, grouped by
/// "Meeting apps → Browsers → Other". The native Picker(.menu) style only
/// supports Text labels, so we hand-roll a Menu to get per-item icons.
struct AudioSourceMenu: View {
    @ObservedObject var recorder: AudioRecorder

    var body: some View {
        Menu {
            Button {
                recorder.selectedApp = nil
            } label: {
                Label {
                    Text("All system audio")
                } icon: {
                    Image(systemName: "speaker.wave.2.fill")
                }
            }

            let grouped = Dictionary(grouping: recorder.runningApps, by: \.bucket)
            ForEach([AudioApp.Bucket.meeting, .browser, .other], id: \.self) { bucket in
                if let apps = grouped[bucket], !apps.isEmpty {
                    Divider()
                    Section(header: Text(bucketLabel(bucket))) {
                        ForEach(apps) { app in
                            Button {
                                recorder.selectedApp = app
                            } label: {
                                Label {
                                    Text(app.name)
                                } icon: {
                                    if let icon = app.icon {
                                        Image(nsImage: icon)
                                    } else {
                                        Image(systemName: "app")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                leadingGlyph
                Text(currentLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if let app = recorder.selectedApp, let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        }
    }

    private var currentLabel: String {
        recorder.selectedApp?.name ?? "All system audio"
    }

    private func bucketLabel(_ bucket: AudioApp.Bucket) -> String {
        switch bucket {
        case .meeting: return "Meeting Apps"
        case .browser: return "Browsers"
        case .other: return "Other Apps"
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
