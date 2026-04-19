import AppKit
import SwiftUI

// MARK: - Top-level panel

struct RecordingPanel: View {
    @ObservedObject var recorder: AudioRecorder
    @Environment(\.openSettings) private var openSettings

    let onOpenFolder: (URL) -> Void
    let onClosePanel: () -> Void

    var body: some View {
        mainView
            .id(stateKey)
            .padding(panelPadding)
            .frame(width: DT.panelWidth)
            .fixedSize(horizontal: false, vertical: true)
            // Pill chrome (rounded bg + border + shadow) is painted by
            // the AppKit `PillShellView` wrapping this NSHostingView.
            // The window auto-resizes to SwiftUI `fittingSize` via a
            // frame observer on PillShellView — no per-state height
            // switch, no clipped/padded mismatches.
    }

    private var panelPadding: EdgeInsets {
        let p = DT.panelPadding
        return EdgeInsets(top: p, leading: p, bottom: p, trailing: p)
    }

    @ViewBuilder
    private var mainView: some View {
        switch recorder.state {
        case .idle:
            IdleState(
                recorder: recorder,
                onGear: presentSettings,
                onRecord: startRecording,
                onClose: onClosePanel
            )
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
                onRetry: { retryProcessing(message) },
                onDismiss: { recorder.reset() }
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
                NSLog("[Recappi] startRecording() calling AudioRecorder.startRecording()")
                try await recorder.startRecording()
                NSLog("[Recappi] startRecording() returned, state now = \(recorder.state)")
            } catch {
                NSLog("[Recappi] startRecording() error: \(error)")
                recorder.state = .error(message: error.localizedDescription)
            }
        }
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

    /// Retry picks up from `lastSessionDir` so we don't call stopRecording
    /// again (which would throw "Not currently recording"). Only transcribe
    /// + summarize get replayed — the capture is already on disk.
    private func retryProcessing(_ message: String) {
        guard let sessionDir = recorder.lastSessionDir else {
            recorder.state = .error(message: "No session to retry")
            return
        }
        Task { await processSession(sessionDir, duration: recorder.elapsedSeconds) }
    }

    private func processSession(_ sessionDir: URL, duration: Int) async {
        do {
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

}

// MARK: - Idle

private struct IdleState: View {
    @ObservedObject var recorder: AudioRecorder
    var onGear: () -> Void
    var onRecord: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            LogoTile(size: 28)

            AudioSourcePill(recorder: recorder)
                .frame(maxWidth: .infinity)

            Button(action: onGear) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(PanelIconButtonStyle())
            .help("Settings (⌘,)")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(PanelIconButtonStyle())
            .keyboardShortcut("w", modifiers: [.command])
            .help("Hide panel (⌘W)")

            PrimaryRecordButton(kind: .record, action: onRecord)
                .keyboardShortcut(.return, modifiers: [])
                .help("Record")
        }
        .frame(height: 28)
        .task { await recorder.refreshApps() }
    }
}

// MARK: - Recording

private struct RecordingState: View {
    @ObservedObject var recorder: AudioRecorder
    var onDiscard: () -> Void
    var onStop: () -> Void

    var body: some View {
        // Caption (red dot + timer + source) sits above the main control row.
        // Same glass shell wraps the whole thing, but the caption is styled
        // as a subtle header so the pill row can carry the main visual
        // weight (logo tile + dot-matrix waveform + controls).
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(DT.systemRed)
                    .frame(width: 6, height: 6)
                    .shadow(color: DT.systemRed.opacity(0.6), radius: 2)
                    .modifier(PulsingModifier())
                Text(formatTime(recorder.elapsedSeconds))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.92))
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.35))
                Text(recordingSourceLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)

            HStack(spacing: 6) {
                DotMatrixWaveform(history: recorder.audioLevelHistory)
                    .frame(maxWidth: .infinity, maxHeight: 28)
                    .padding(.leading, 4)

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
            .frame(height: 28)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
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
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 2)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(DT.waveformLit)
                            .frame(width: width * (barPhase ? 0.92 : 0.18), height: 2)
                            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 1.8).repeatForever(autoreverses: true), value: barPhase)
                    }
            }
            .frame(height: 2)
            .onAppear { barPhase = true }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
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
                    .foregroundStyle(Color.black.opacity(0.9))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(DT.waveformLit))
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))

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
                Button("Done", action: onNew).buttonStyle(PanelPushButtonStyle(primary: true))
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
            RoundedRectangle(cornerRadius: DT.R.card, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DT.R.card, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
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
    var onDismiss: () -> Void

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

                // Dismiss — the only way back to idle when retry isn't an
                // option and the user just wants to close the panel's error
                // state without opening Settings.
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(PanelIconButtonStyle(size: 22))
                .help("Dismiss")
            }

            actionsRow
        }
    }

    @ViewBuilder
    private var actionsRow: some View {
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

/// Source picker — SwiftUI pill trigger, native NSMenu for the dropdown.
/// Building our own popup never matched the system menu's chrome; using
/// `NSMenu.popUp()` gives real macOS styling (material, hover, keyboard
/// nav) without fighting AppKit.
struct AudioSourcePill: View {
    @ObservedObject var recorder: AudioRecorder
    @State private var anchor: NSView?
    @State private var hovered = false

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 6) {
                if let app = recorder.selectedApp, let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text(currentLabel)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.dtLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.dtLabelSecondary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .fill(DT.recordingChip.opacity(hovered ? 1.0 : 0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: DT.R.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DT.ease(0.12), value: hovered)
        .background {
            // No explicit frame — the anchor NSView fills the pill so
            // anchor.convert(bounds, to: nil) returns the pill's real
            // window-space frame. A 0×0 frame would collapse to the
            // center and we'd pop the menu 90pt to the right.
            MenuAnchorView { anchor = $0 }
        }
    }

    private var currentLabel: String {
        recorder.selectedApp?.name ?? "All system audio"
    }

    private func showMenu() {
        guard let anchor, let window = anchor.window else { return }
        let menu = buildMenu()
        let origin = menuPopUpLocation(for: menu, anchor: anchor, window: window)
        menu.popUp(positioning: nil, at: origin, in: nil)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.appearance = anchor?.window?.effectiveAppearance
        menu.autoenablesItems = true

        menu.addItem(menuItem(
            title: "All system audio",
            image: NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil),
            app: nil
        ))

        let activeApps = recorder.runningApps.filter { $0.isActive }
        if !activeApps.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Now Playing"))
            for app in activeApps { menu.addItem(menuItem(title: app.name, image: app.icon, app: app)) }
        }

        let grouped = Dictionary(grouping: recorder.runningApps.filter { !$0.isActive }, by: \.bucket)
        for (bucket, label) in [
            (AudioApp.Bucket.meeting, "Meeting apps"),
            (.browser, "Browsers"),
            (.other, "Other apps"),
        ] {
            guard let apps = grouped[bucket], !apps.isEmpty else { continue }
            menu.addItem(.separator())
            menu.addItem(sectionHeader(label))
            for app in apps { menu.addItem(menuItem(title: app.name, image: app.icon, app: app)) }
        }
        return menu
    }

    private func menuItem(title: String, image: NSImage?, app: AudioApp?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sleeve = MenuClosure { [recorder] in recorder.selectedApp = app }
        item.representedObject = sleeve
        item.target = sleeve
        item.action = #selector(MenuClosure.invoke)
        if let image {
            image.size = NSSize(width: 16, height: 16)
            item.image = image
        }
        item.state = (app?.id == recorder.selectedApp?.id) ? .on : .off
        return item
    }

    private func sectionHeader(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 0.6,
            ]
        )
        return item
    }

    private func menuPopUpLocation(for menu: NSMenu, anchor: NSView, window: NSWindow) -> CGPoint {
        let anchorBoundsInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorFrameOnScreen = window.convertToScreen(anchorBoundsInWindow)
        let screen = window.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        let menuSize = menu.size
        let inset: CGFloat = 8

        var location = CGPoint(
            x: anchorFrameOnScreen.minX,
            y: anchorFrameOnScreen.minY - 4
        )
        location.x = min(
            max(location.x, visibleFrame.minX + inset),
            max(visibleFrame.minX + inset, visibleFrame.maxX - menuSize.width - inset)
        )
        location.y = min(
            max(location.y, visibleFrame.minY + menuSize.height + inset),
            visibleFrame.maxY - inset
        )
        return location
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let onUpdate: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onUpdate(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onUpdate(nsView) }
    }
}

private final class MenuClosure: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}

// MARK: - Dot-matrix waveform

/// Rolling LED-matrix waveform. Each column is one `audioLevelHistory`
/// sample; as new samples arrive, the history advances so the matrix
/// scrolls right-to-left, newest on the right. Fills the full Canvas
/// width — `colStep` / `rowStep` scale with size, dots sized to 60% of
/// the smaller cell axis so they stay round regardless of aspect.
struct DotMatrixWaveform: View {
    let history: [Float]

    private let rows: Int = 5

    var body: some View {
        Canvas { ctx, size in
            let cols = history.count
            guard cols > 0 else { return }
            let colStep = size.width / CGFloat(cols)
            let rowStep = size.height / CGFloat(rows)
            let dotSize = min(colStep, rowStep) * 0.6

            for c in 0..<cols {
                // sqrt compresses: voice peaks hover 0.1-0.3 linear; this
                // maps that range into the visible middle of the bar.
                let amp = sqrt(max(0, min(1, CGFloat(history[c]))))
                let lit = Int((amp * CGFloat(rows)).rounded())
                // Bottom-aligned: rows grow from the baseline upward.
                let firstLit = rows - lit
                for r in 0..<rows {
                    let x = CGFloat(c) * colStep + (colStep - dotSize) / 2
                    let y = CGFloat(r) * rowStep + (rowStep - dotSize) / 2
                    let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                    let color: Color = r >= firstLit
                        ? DT.waveformLit
                        : DT.waveformUnlit
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .animation(.linear(duration: 0.05), value: history)
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
