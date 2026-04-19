import AppKit
import SwiftUI

// MARK: - Top-level panel

struct RecordingPanel: View {
    @ObservedObject var recorder: AudioRecorder
    @Environment(\.openSettings) private var openSettings

    let onOpenFolder: (URL) -> Void

    var body: some View {
        mainView
            .padding(DT.panelPadding)
            .frame(width: DT.panelWidth)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(GlassBackgroundModifier())
            .animation(DT.ease(0.22), value: stateKey)
            .onChange(of: stateKey) { resizeToTarget() }
    }

    @ViewBuilder
    private var mainView: some View {
        switch recorder.state {
        case .idle: IdleState(recorder: recorder, onGear: presentSettings, onRecord: startRecording)
        case .recording: RecordingState(recorder: recorder, onDiscard: discardRecording, onStop: stopRecording)
        case .stopping, .transcribing, .summarizing: ProcessingState(recorder: recorder)
        case .done(let r):
            DoneState(
                result: r,
                onShow: { onOpenFolder(r.folderURL) },
                onCopy: { copyInsights(r) },
                onNew: { recorder.reset() }
            )
        case .error(let message):
            ErrorState(
                recorder: recorder,
                message: message,
                onShow: { if let dir = recorder.lastSessionDir { onOpenFolder(dir) } },
                onSettings: presentSettings,
                onRetry: { retryProcessing(message) }
            )
        }
    }

    // MARK: - Actions

    /// Flip activation policy so the Settings window comes to the foreground,
    /// then bounce back in SettingsView.onDisappear.
    private func presentSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
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
        Task { await runProcessing() }
    }

    private func retryProcessing(_ message: String) {
        Task { await runProcessing() }
    }

    private func runProcessing() async {
        do {
            let duration = recorder.elapsedSeconds
            let sessionDir = try await recorder.stopRecording()
            let config = AppConfig.shared
            let transcriber = createTranscriber(config: config)

            recorder.state = .transcribing
            let audioURL = RecordingStore.audioFileURL(in: sessionDir)
            let transcript = try await transcriber.transcribe(audioURL: audioURL)
            try RecordingStore.saveTranscript(transcript, in: sessionDir)

            var insights: MeetingInsights? = nil
            if config.selectedProvider != .none {
                recorder.state = .summarizing
                let provider = createInsightsProvider(config: config)
                let extracted = try await provider.extract(transcript: transcript)
                try RecordingStore.saveSummary(extracted, in: sessionDir)
                try RecordingStore.saveActionItems(extracted.actionItems, in: sessionDir)
                insights = extracted
            }

            recorder.state = .done(result: RecordingResult(
                folderURL: sessionDir,
                transcript: transcript,
                duration: duration,
                insights: insights
            ))
        } catch {
            recorder.state = .error(message: error.localizedDescription)
        }
    }

    private func discardRecording() {
        Task {
            try? await recorder.stopRecording()
            recorder.reset()
        }
    }

    /// "Copy" in the done state copies summary + action items if we have
    /// them; otherwise falls back to the raw transcript.
    private func copyInsights(_ r: RecordingResult) {
        var body = ""
        if let s = r.insights?.summary, !s.isEmpty {
            body += s.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            if let items = r.insights?.actionItems, !items.isEmpty {
                body += "\nAction items:\n"
                for item in items {
                    body += "- "
                    if let owner = item.owner, !owner.isEmpty { body += "\(owner): " }
                    body += item.text
                    if let due = item.due, !due.isEmpty { body += " (due \(due))" }
                    body += "\n"
                }
            }
        } else if let t = r.transcript, !t.isEmpty {
            body = t
        }
        guard !body.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }

    // MARK: - Sizing

    private var stateKey: String {
        switch recorder.state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .stopping, .transcribing, .summarizing: return "processing"
        case .done(let r):
            let hasSummary = r.insights?.summary.isEmpty == false
            let hasTranscript = (r.transcript ?? "").isEmpty == false
            return "done-\(hasSummary ? "full" : (hasTranscript ? "transcript" : "bare"))"
        case .error(let m):
            return "error-\(recorder.lastSessionDir != nil ? "recoverable" : "plain")-\(m.count)"
        }
    }

    private var targetHeight: CGFloat {
        switch recorder.state {
        case .idle: return 48
        case .recording: return 64
        case .stopping, .transcribing, .summarizing: return 68
        case .done(let r):
            if r.insights?.summary.isEmpty == false { return 210 }
            if (r.transcript ?? "").isEmpty == false { return 140 }
            return 60
        case .error:
            return recorder.lastSessionDir != nil ? 108 : 72
        }
    }

    private func resizeToTarget() {
        guard let window = NSApp.windows.first(where: { $0 is FloatingPanel }) as? FloatingPanel else { return }
        FloatingPanelController.resize(window, height: targetHeight + DT.panelPadding * 2)
    }
}

// MARK: - Glass background

struct GlassBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: DT.R.panel))
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: DT.R.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DT.R.panel)
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
                .shadow(color: .black.opacity(0.20), radius: 6, y: 3)
        }
    }
}

// MARK: - Idle

private struct IdleState: View {
    @ObservedObject var recorder: AudioRecorder
    var onGear: () -> Void
    var onRecord: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            AudioSourcePill(recorder: recorder)

            Button(action: onGear) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(PanelIconButtonStyle())
            .help("Settings (⌘,)")

            PrimaryRecordButton(kind: .record, action: onRecord)
                .keyboardShortcut(.return, modifiers: [])
                .help("Record")
        }
        .task { await recorder.refreshApps() }
    }
}

// MARK: - Recording

private struct RecordingState: View {
    @ObservedObject var recorder: AudioRecorder
    var onDiscard: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(formatTime(recorder.elapsedSeconds))
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.dtLabel)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Circle()
                        .fill(DT.systemRed)
                        .frame(width: 6, height: 6)
                        .shadow(color: DT.systemRed.opacity(0.6), radius: 2)
                        .modifier(PulsingModifier())
                    Text(recordingSourceLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dtLabelSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            AudioMeter(level: recorder.audioLevel)
                .frame(width: 44, height: 16)

            Button(action: onDiscard) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(PanelIconButtonStyle())
            .help("Discard")

            PrimaryRecordButton(kind: .stop, action: onStop)
                .keyboardShortcut(.return, modifiers: [])
                .help("Stop")
        }
    }

    private var recordingSourceLabel: String {
        recorder.recordingAppName ?? recorder.selectedApp?.name ?? "All system audio"
    }

    private func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Processing

private struct ProcessingState: View {
    @ObservedObject var recorder: AudioRecorder
    @State private var spin = false
    @State private var barPhase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.dtLabel, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.dtLabel)
                    Text(step)
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.dtLabelSecondary)
                }

                Spacer(minLength: 0)
            }

            // Animated progress bar: grows 18% → 92% and back
            GeometryReader { geo in
                let width = geo.size.width
                Capsule()
                    .fill(Color.black.opacity(0.08))
                    .frame(height: 2)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.dtLabel)
                            .frame(width: width * (barPhase ? 0.92 : 0.18), height: 2)
                            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 1.8).repeatForever(autoreverses: true), value: barPhase)
                    }
            }
            .frame(height: 2)
            .onAppear { barPhase = true }
        }
    }

    private var title: String {
        switch recorder.state {
        case .stopping: return "Saving audio…"
        case .transcribing: return "Transcribing…"
        case .summarizing: return "Summarizing…"
        default: return "Processing…"
        }
    }

    private var step: String {
        let total = AppConfig.shared.selectedProvider == .none ? 2 : 3
        let current: Int
        switch recorder.state {
        case .stopping: current = 1
        case .transcribing: current = 2
        case .summarizing: current = 3
        default: current = 0
        }
        return "Step \(current) of \(total)"
    }
}

// MARK: - Done

private struct DoneState: View {
    let result: RecordingResult
    var onShow: () -> Void
    var onCopy: () -> Void
    var onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(DT.systemGreen))
                    .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 0.5))

                Text("Meeting saved")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)

                Spacer(minLength: 0)

                Text(formatTime(result.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.dtLabelSecondary)
            }

            if hasSummary || hasTranscript {
                summaryCard
            }

            HStack(spacing: 6) {
                Button("Show", action: onShow).buttonStyle(PanelPushButtonStyle())
                Button("Copy", action: onCopy).buttonStyle(PanelPushButtonStyle())
                Button("New", action: onNew).buttonStyle(PanelPushButtonStyle(primary: true))
            }
        }
    }

    @ViewBuilder
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Summary")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.05 * 10.5)
                .textCase(.uppercase)
                .foregroundStyle(Color.dtLabelSecondary)

            Text(summaryBody)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.dtLabel)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if !actionItemsToShow.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(actionItemsToShow.indices, id: \.self) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle()
                                .fill(Color.dtLabelSecondary)
                                .frame(width: 3, height: 3)
                                .padding(.top, 5)
                            Text(actionItemsToShow[i])
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.dtLabel)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DT.R.card)
                .fill(Color.white.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DT.R.card)
                .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var hasSummary: Bool { !(result.insights?.summary.isEmpty ?? true) }
    private var hasTranscript: Bool { !(result.transcript ?? "").isEmpty }

    private var summaryBody: String {
        if let s = result.insights?.summary, !s.isEmpty { return s }
        return result.transcript ?? ""
    }

    /// First 3 action items formatted as "Owner: text" or just text.
    private var actionItemsToShow: [String] {
        guard let items = result.insights?.actionItems else { return [] }
        return items.prefix(3).map { item in
            if let owner = item.owner, !owner.isEmpty {
                return "\(owner): \(item.text)"
            }
            return item.text
        }
    }

    private func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Error

private struct ErrorState: View {
    @ObservedObject var recorder: AudioRecorder
    let message: String
    var onShow: () -> Void
    var onSettings: () -> Void
    var onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DT.systemOrange)
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.dtLabel)
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.dtLabelSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if recorder.lastSessionDir != nil {
                HStack(spacing: 6) {
                    Button("Show", action: onShow).buttonStyle(PanelPushButtonStyle())
                    if isConfigRelated {
                        Button("Settings…", action: onSettings).buttonStyle(PanelPushButtonStyle())
                    }
                    Button("Retry", action: onRetry).buttonStyle(PanelPushButtonStyle(primary: true))
                }
            } else if isConfigRelated {
                HStack(spacing: 6) {
                    Button("Settings…", action: onSettings).buttonStyle(PanelPushButtonStyle(primary: true))
                }
            }
        }
    }

    private var title: String {
        recorder.lastSessionDir != nil ? "Processing failed" : "Recording failed"
    }

    private var isConfigRelated: Bool {
        let lower = message.lowercased()
        return lower.contains("api")
            || lower.contains("key")
            || lower.contains("auth")
            || lower.contains("language not supported")
            || lower.contains("apple intelligence")
    }
}

// MARK: - Audio source pill

/// Design's `.source-pill` — a menu button styled like an NSPopUpButton with
/// white tint. Opens a Menu with grouped app list (Now Playing / Meeting
/// apps / Browsers / Other apps) mirroring the design's picker.
struct AudioSourcePill: View {
    @ObservedObject var recorder: AudioRecorder
    @State private var hovered = false

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

            let activeApps = recorder.runningApps.filter { $0.isActive }
            if !activeApps.isEmpty {
                Divider()
                Section("Now Playing") {
                    ForEach(activeApps) { appItem($0) }
                }
            }

            let grouped = Dictionary(grouping: recorder.runningApps.filter { !$0.isActive }, by: \.bucket)
            ForEach([AudioApp.Bucket.meeting, .browser, .other], id: \.self) { bucket in
                if let apps = grouped[bucket], !apps.isEmpty {
                    Divider()
                    Section(bucketLabel(bucket)) {
                        ForEach(apps) { appItem($0) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                leadingIcon
                Text(currentLabel)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.dtLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.dtLabelSecondary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: DT.R.control)
                    .fill(Color.white.opacity(hovered ? 0.96 : 0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.R.control)
                    .stroke(Color.black.opacity(0.09), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 0.5, y: 0.5)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { hovered = $0 }
        .animation(DT.ease(0.12), value: hovered)
    }

    @ViewBuilder
    private func appItem(_ app: AudioApp) -> some View {
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

    @ViewBuilder
    private var leadingIcon: some View {
        if let app = recorder.selectedApp, let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.dtLabelSecondary)
                .frame(width: 14, height: 14)
        }
    }

    private var currentLabel: String {
        recorder.selectedApp?.name ?? "All system audio"
    }

    private func bucketLabel(_ bucket: AudioApp.Bucket) -> String {
        switch bucket {
        case .meeting: return "Meeting apps"
        case .browser: return "Browsers"
        case .other: return "Other apps"
        }
    }
}

// MARK: - Audio meter (7 bars)

/// Mirrors design's `.meter` — 7 vertical bars with staggered heights.
/// Real audio level drives overall amplitude; bars still pulse asymmetrically
/// via per-bar phase offsets so the control reads as "live mic" rather
/// than a static indicator.
struct AudioMeter: View {
    let level: Float  // 0…1

    private static let heights: [CGFloat] = [0.45, 0.75, 1.00, 0.60, 0.85, 0.50, 0.70]
    @State private var phase: [Double] = [0.1, 0.3, 0.5, 0.2, 0.6, 0.4, 0.1]
    @State private var tick = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<7, id: \.self) { i in
                Capsule()
                    .fill(Color.dtLabelSecondary)
                    .frame(width: 2, height: barHeight(for: i))
            }
        }
        .frame(width: 44, height: 16)
        .onAppear { tick.toggle() }
        .animation(
            .easeInOut(duration: 0.45).repeatForever(autoreverses: true),
            value: tick
        )
    }

    private func barHeight(for index: Int) -> CGFloat {
        let full = 16 * Self.heights[index]
        let amp = max(0.35, CGFloat(level) * 1.4 + CGFloat(0.35))
        let scaled = full * amp
        return tick ? scaled : max(full * 0.35, 4)
    }
}

// MARK: - Pulsing modifier (kept for the tiny recording-dot)

struct PulsingModifier: ViewModifier {
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(pulsing ? 0.35 : 1)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
