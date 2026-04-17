import SwiftUI

struct RecordingPanel: View {
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject private var config = AppConfig.shared
    @State private var showSettings = false
    @State private var processingStart: Date?
    @State private var justCopied = false
    @State private var previewExpanded = false

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
        .onChange(of: recorder.state) { _, newState in
            if newState.isProcessing {
                if processingStart == nil { processingStart = Date() }
            } else {
                processingStart = nil
            }
            // Any state change collapses the preview — a new recording shouldn't
            // open pre-expanded, and a retry starts fresh.
            previewExpanded = false
        }
    }

    // MARK: - Design tokens / reusable pieces

    private enum PrimaryActionKind { case record, stop }

    /// Unified 18×18 slot for the state-leading glyph (speaker, level meter,
    /// spinner, checkmark, warning). Keeps every row's left column visually
    /// aligned regardless of what the state is showing.
    @ViewBuilder
    private func statusGlyph<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().frame(width: 18, height: 18)
    }

    /// Standard chrome icon button (12pt .secondary default, rounded hover fill).
    /// Used for settings, trash, folder, copy — the "row actions" that sit
    /// between the state info and the primary action.
    @ViewBuilder
    private func chromeIconButton(
        _ systemImage: String,
        color: Color = .secondary,
        action: @escaping () -> Void,
        help: String
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(color)
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
    }

    /// Dismiss ✕ — deliberately smaller/dimmer than other chrome buttons so
    /// it reads as "quiet close" and doesn't compete with primary actions.
    @ViewBuilder
    private func dismissButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(IconButtonStyle())
        .help("Dismiss")
    }

    /// Record / Stop share one visual system — 24pt red circle with a white
    /// indicator. Same size so the primary action doesn't jump between
    /// idle→recording.
    @ViewBuilder
    private func primaryActionButton(kind: PrimaryActionKind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.red)
                    .frame(width: 24, height: 24)
                switch kind {
                case .record:
                    Circle()
                        .fill(.white)
                        .frame(width: 9, height: 9)
                case .stop:
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white)
                        .frame(width: 9, height: 9)
                }
            }
        }
        .buttonStyle(.plain)
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
            HStack(spacing: 6) {
                statusGlyph {
                    if let app = recorder.selectedApp, let icon = app.icon {
                        Image(nsImage: icon).interpolation(.high)
                    } else {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
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

            chromeIconButton("gearshape", action: { showSettings = true }, help: "Settings")

            primaryActionButton(kind: .record, action: { recorder.startFlow() })
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
            statusGlyph {
                AudioLevelMeter(level: recorder.audioLevel)
                    .frame(width: 14, height: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(formatTime(recorder.elapsedSeconds))
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    if let app = recorder.selectedApp, let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 12, height: 12)
                    }
                    Text(recorder.recordingAppName ?? "All system audio")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            chromeIconButton("trash", action: { recorder.cancelFlow() }, help: "Discard recording — deletes the session folder")

            primaryActionButton(kind: .stop, action: { recorder.stopFlow() })
                .help("Stop recording")
                .keyboardShortcut(.return, modifiers: [])
        }
    }

    // MARK: - Processing

    private var processingContent: some View {
        HStack(spacing: 10) {
            statusGlyph {
                ProgressView().scaleEffect(0.6)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(processingLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 0)

                    if let start = processingStart {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            Text(formatTime(Int(context.date.timeIntervalSince(start))))
                                .font(.system(size: 11, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ProcessingStepsIndicator(
                    current: currentProcessingStep,
                    total: processingStepsTotal
                )
            }
        }
    }

    private var currentProcessingStep: Int {
        switch recorder.state {
        case .stopping: return 1
        case .transcribing: return 2
        case .summarizing: return 3
        default: return 0
        }
    }

    private var processingStepsTotal: Int {
        AppConfig.shared.selectedProvider == .none ? 2 : 3
    }

    // MARK: - Done

    private func doneContent(result: RecordingResult) -> some View {
        let preview = donePreview(result: result)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusGlyph {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 16))
                }
                Text("Recording saved")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(formatTime(result.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let text = copyableText(result: result) {
                    Button(action: { copyToClipboard(text) }) {
                        Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(justCopied ? .green : .secondary)
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(justCopied ? "Copied" : "Copy \(result.summary?.isEmpty == false ? "summary" : "transcript") to clipboard")
                }
                chromeIconButton("folder", color: .blue, action: { onOpenFolder(result.folderURL) }, help: "Open folder")
                dismissButton { recorder.reset() }
            }

            if let preview {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(preview.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                        Spacer()
                        Image(systemName: previewExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    if previewExpanded {
                        ScrollView {
                            Text(preview.body)
                                .font(.system(size: 11))
                                .foregroundStyle(preview.isSummary ? .primary : .secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                    } else {
                        Text(preview.body)
                            .font(.system(size: 11))
                            .foregroundStyle(preview.isSummary ? .primary : .secondary)
                            .lineLimit(preview.isSummary ? 5 : 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { previewExpanded.toggle() }
                .help(previewExpanded ? "Collapse" : "Expand to read full text")
            }
        }
    }

    private struct DonePreview {
        let label: String
        let body: String
        let isSummary: Bool
    }

    private func copyableText(result: RecordingResult) -> String? {
        if let s = result.summary, !s.isEmpty { return s }
        if let t = result.transcript, !t.isEmpty { return t }
        return nil
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        justCopied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            justCopied = false
        }
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
        let title = recoverable ? "Processing failed" : "Recording failed"

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusGlyph {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 16))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                dismissButton { recorder.reset() }
            }

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if recoverable || configIssue {
                HStack(spacing: 8) {
                    if recoverable {
                        Button(action: { recorder.retryFlow() }) {
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
        if showSettings {
            return AppConfig.shared.selectedProvider == .none ? "settings-none" : "settings-llm"
        }
        switch recorder.state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .stopping, .transcribing, .summarizing: return "processing"
        case .done(let r):
            let hasPreview = (r.summary?.isEmpty == false) || (r.transcript?.isEmpty == false)
            if previewExpanded && hasPreview { return "done-expanded" }
            if let s = r.summary, !s.isEmpty { return "done-summary" }
            return (r.transcript ?? "").isEmpty ? "done-short" : "done-transcript"
        case .error(let msg): return errorHasActions(msg) ? "error-actions" : "error-short"
        }
    }

    private var targetHeight: CGFloat {
        if showSettings {
            return AppConfig.shared.selectedProvider == .none ? 160 : 340
        }
        switch recorder.state {
        case .idle: return 56
        case .recording: return 72
        case .stopping, .transcribing, .summarizing: return 68
        case .done(let r):
            let hasPreview = (r.summary?.isEmpty == false) || (r.transcript?.isEmpty == false)
            if previewExpanded && hasPreview { return 300 }
            if let s = r.summary, !s.isEmpty { return 140 }
            return (r.transcript ?? "").isEmpty ? 52 : 110
        case .error(let msg): return errorHasActions(msg) ? 112 : 78
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

/// Small icon button with a subtle rounded hover/pressed background.
/// Intended for panel chrome (gear, folder, dismiss) — not the big record/stop buttons.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 22

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBackground(isPressed: configuration.isPressed, size: size) {
            configuration.label
        }
    }
}

private struct IconButtonBackground<Content: View>: View {
    let isPressed: Bool
    let size: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        content()
            .frame(width: size, height: size)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(fillOpacity))
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: isPressed)
    }

    private var fillOpacity: Double {
        if isPressed { return 0.18 }
        if isHovered { return 0.10 }
        return 0
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

/// Three dots with connecting lines: done dots are filled, the current dot
/// pulses, future dots are outlined. Skips the third dot when summarizing
/// is disabled (LLM provider = none).
struct ProcessingStepsIndicator: View {
    let current: Int   // 1-based step index; 0 means none active
    let total: Int     // 2 or 3
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...total, id: \.self) { step in
                dot(for: step)
                if step < total {
                    Capsule()
                        .fill(step < current ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.3))
                        .frame(width: 12, height: 1.5)
                }
            }
        }
        .onAppear { pulse = true }
    }

    @ViewBuilder
    private func dot(for step: Int) -> some View {
        if step < current {
            Circle()
                .fill(Color.accentColor.opacity(0.8))
                .frame(width: 6, height: 6)
        } else if step == current {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .scaleEffect(pulse ? 1.3 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
        } else {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                .frame(width: 6, height: 6)
        }
    }
}

/// Four vertical bars (short → tall) that light up progressively with the
/// normalized audio level. Reads as "signal strength" — steady faint when
/// silent (so user sees "recording, waiting for sound") and ramps to full
/// red when the mic/system audio is hot.
struct AudioLevelMeter: View {
    let level: Float  // 0…1

    private let barCount = 4
    private let heights: [CGFloat] = [4, 7, 11, 15]
    private let barWidth: CGFloat = 2
    private let spacing: CGFloat = 1.5

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.red.opacity(opacity(for: i)))
                    .frame(width: barWidth, height: heights[i])
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }

    /// Bar i lights when level crosses (i+1)/barCount. Inactive bars keep a
    /// dim glow so the meter still reads as an audio indicator at silence.
    private func opacity(for index: Int) -> Double {
        let threshold = Float(index + 1) / Float(barCount + 1)
        if level >= threshold { return 1.0 }
        // Soft ramp near threshold for visual smoothness
        let prevThreshold = Float(index) / Float(barCount + 1)
        if level > prevThreshold {
            let t = (level - prevThreshold) / (threshold - prevThreshold)
            return 0.25 + Double(t) * 0.75
        }
        return 0.25
    }
}
