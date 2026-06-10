import AppKit
import SwiftUI

/// Shows the live captions captured while recording, as a stand-in inside the
/// transcript card before the cloud transcript is ready — so the user has
/// something to read during the transcribing wait instead of an empty
/// "in progress" state. Once the real transcript arrives the caller stops
/// rendering this (segment rows take over); for local-only recordings these
/// captions are the only transcript and stay shown.
///
/// Deliberately distinct from the official transcript: it is labelled "Live
/// Captions", never feeds the cloud transcript, and exports honestly — SRT/VTT
/// are only offered when the source carried real per-line timing
/// (`transcript.hasTimestamps`), never fabricated.
struct CloudDetailLiveCaptionsPreview: View {
    let transcript: LiveCaptionTranscript
    /// True while the cloud transcript/summary is still being generated, so
    /// the header can tell the user the official transcript is still coming.
    let isProcessing: Bool

    @State private var exportErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.borderHairline)
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(transcript.lines) { line in
                    lineView(line)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityIDs.Cloud.liveCaptionsPreview)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surfaceCardSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.borderHairline, lineWidth: 1)
        )
        .alert(
            "Couldn't export live captions",
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            if let exportErrorMessage {
                Text(exportErrorMessage)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.dtLabelSecondary)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text("Live Captions")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                    .padding(.trailing, 2)
            }

            Button(action: copyToPasteboard) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(PanelIconButtonStyle(size: 24))
            .recappiTooltip("Copy live captions")

            exportMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var exportMenu: some View {
        Menu {
            Button("Export as Text (.txt)") { export(.plainText) }
            if transcript.hasTimestamps {
                Button("Export as SubRip (.srt)") { export(.srt) }
                Button("Export as WebVTT (.vtt)") { export(.vtt) }
            }
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 24)
        .recappiTooltip("Export live captions")
    }

    @ViewBuilder
    private func lineView(_ line: LiveCaptionTranscriptLine) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let stamp = timecode(for: line) {
                Text(stamp)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.dtLabelTertiary)
            }
            if !line.source.isEmpty {
                Text(line.source)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.dtLabel)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let translation = line.translation,
               !translation.isEmpty,
               translation != line.source {
                Text(translation)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        if isProcessing {
            return "Transcribing… showing live captions in the meantime"
        }
        return "Captured live during this recording"
    }

    private func timecode(for line: LiveCaptionTranscriptLine) -> String? {
        guard transcript.hasTimestamps, let startMs = line.startMs else { return nil }
        let totalSeconds = max(0, startMs) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func copyToPasteboard() {
        let text = LiveCaptionTranscriptExporter.plainText(transcript)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private enum ExportKind {
        case plainText, srt, vtt

        var fileExtension: String {
            switch self {
            case .plainText: "txt"
            case .srt: "srt"
            case .vtt: "vtt"
            }
        }
    }

    private func export(_ kind: ExportKind) {
        let content: String?
        switch kind {
        case .plainText: content = LiveCaptionTranscriptExporter.plainText(transcript)
        case .srt: content = LiveCaptionTranscriptExporter.srt(transcript)
        case .vtt: content = LiveCaptionTranscriptExporter.vtt(transcript)
        }
        guard let content, !content.isEmpty else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "live-captions.\(kind.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }
}

#Preview("Live Captions — bilingual, transcribing") {
    CloudDetailLiveCaptionsPreview(
        transcript: LiveCaptionTranscript(
            lines: [
                LiveCaptionTranscriptLine(id: 0, startMs: 0, endMs: 2400, source: "Let's start with the roadmap.", translation: "我们先从路线图开始。", isFinal: true),
                LiveCaptionTranscriptLine(id: 1, startMs: 2400, endMs: 6200, source: "Q3 is focused on reliability and the new capture pipeline.", translation: "三季度聚焦稳定性和新的采集管线。", isFinal: true),
                LiveCaptionTranscriptLine(id: 2, startMs: 6200, endMs: 9000, source: "Any blockers on the audio side?", translation: "音频这边有什么阻塞吗？", isFinal: false),
            ],
            hasTimestamps: false,
            hasTranslation: true,
            isLegacyMashed: false
        ),
        isProcessing: true
    )
    .frame(width: 420)
    .padding(24)
}

#Preview("Live Captions — source only, done") {
    CloudDetailLiveCaptionsPreview(
        transcript: LiveCaptionTranscript(
            lines: [
                LiveCaptionTranscriptLine(id: 0, startMs: nil, endMs: nil, source: "Welcome everyone, thanks for joining.", translation: nil, isFinal: true),
                LiveCaptionTranscriptLine(id: 1, startMs: nil, endMs: nil, source: "Let's keep it to twenty minutes today.", translation: nil, isFinal: true),
            ],
            hasTimestamps: false,
            hasTranslation: false,
            isLegacyMashed: false
        ),
        isProcessing: false
    )
    .frame(width: 420)
    .padding(24)
}
