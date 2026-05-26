import AppKit
import SwiftUI

struct IdleState: View {
    @ObservedObject var recorder: AudioRecorder

    let isStarting: Bool
    var onCloud: () -> Void
    var onRecord: () -> Void
    var onRecordSuggestion: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            controlsRow

            if !isStarting {
                if let suggestion = recorder.recordingSuggestion {
                    Button(action: onRecordSuggestion) {
                        HStack(spacing: 8) {
                            hintContent(
                                title: suggestion.promptTitle,
                                appName: suggestion.appName,
                                appID: suggestion.appID
                            )
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .layoutPriority(1)

                            Text("Record app")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DT.recordingLiveBlue)
                                .padding(.horizontal, 6)
                                .frame(height: 16)
                                .fixedSize(horizontal: true, vertical: false)
                                .background(
                                    Capsule()
                                        .fill(DT.recordingLiveBlue.opacity(0.13))
                                )
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 2)
                    .padding(.trailing, hintTrailingInset)
                    .accessibilityLabel(meetingHintText(title: suggestion.promptTitle, appName: suggestion.appName))
                    .accessibilityIdentifier(AccessibilityIDs.Panel.recordingSuggestion)
                    .help("Record only \(suggestion.appName). Use the source menu to keep recording all system audio.")
                } else if let prompt = recorder.meetingPrompt {
                    hintRow(title: prompt.promptTitle, appName: prompt.appName, appID: prompt.appID)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(meetingHintText(title: prompt.promptTitle, appName: prompt.appName))
                        .accessibilityIdentifier(AccessibilityIDs.Panel.meetingPrompt)
                        .help("Recappi Mini selected \(prompt.appName) because it looks like a meeting is active.")
                }
            }
        }
        .task {
            guard recorder.runningApps.isEmpty else { return }
            await recorder.refreshApps()
        }
    }

    private func hintRow(title: String, appName: String, appID: String) -> some View {
        HStack(spacing: 0) {
            hintContent(title: title, appName: appName, appID: appID)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 2)
        .padding(.trailing, hintTrailingInset)
        .accessibilityElement(children: .combine)
    }

    private func hintContent(title: String, appName: String, appID: String) -> some View {
        let parts = meetingHintParts(title: title, appName: appName)
        return HStack(spacing: 4) {
            Text(parts.prefix)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.dtLabelSecondary)
                .lineLimit(1)

            if let source = parts.source {
                if let icon = icon(for: appID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 12, height: 12)
                        .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                        .accessibilityHidden(true)
                }
                Text(source)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .lineLimit(1)
            }
        }
        .lineLimit(1)
        .multilineTextAlignment(.trailing)
    }

    private var hintTrailingInset: CGFloat {
        // Right-align meeting hints so the CTA and hint read as one compact
        // cluster instead of competing with the logo/source-picker columns.
        2
    }

    private func icon(for appID: String) -> NSImage? {
        recorder.runningApps.first(where: { $0.id == appID })?.icon
    }

    private func meetingHintParts(title: String, appName: String) -> (prefix: String, source: String?) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedApp = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return (
                trimmedApp.isEmpty ? "Meeting audio detected" : "\(trimmedApp) may be in a meeting",
                nil
            )
        }

        if trimmedTitle.compare(trimmedApp, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return ("\(trimmedApp) may be in a meeting", nil)
        }

        if let range = trimmedTitle.range(of: " in ", options: [.caseInsensitive, .backwards]) {
            let service = trimmedTitle[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let source = trimmedTitle[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !service.isEmpty && !source.isEmpty {
                return ("\(service) detected in", source)
            }
        }

        guard !trimmedApp.isEmpty else { return ("\(trimmedTitle) detected", nil) }
        return ("\(trimmedTitle) detected in", trimmedApp)
    }

    private func meetingHintText(title: String, appName: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedApp = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return trimmedApp.isEmpty ? "Meeting audio detected" : "\(trimmedApp) may be in a meeting"
        }

        if trimmedTitle.compare(trimmedApp, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return "\(trimmedApp) may be in a meeting"
        }

        if let range = trimmedTitle.range(of: " in ", options: [.caseInsensitive, .backwards]) {
            let service = trimmedTitle[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let source = trimmedTitle[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !service.isEmpty && !source.isEmpty {
                return "\(service) detected in \(source)"
            }
        }

        guard !trimmedApp.isEmpty else { return "\(trimmedTitle) detected" }
        return "\(trimmedTitle) detected in \(trimmedApp)"
    }

    private var controlsRow: some View {
        HStack(spacing: 6) {
            Button(action: onCloud) {
                LogoTile(size: 28)
            }
            .buttonStyle(.plain)
            .disabled(isStarting)
            .help("Open Recappi Cloud")
            .accessibilityIdentifier(AccessibilityIDs.Panel.cloudButton)

            AudioSourcePill(recorder: recorder)
                .frame(maxWidth: .infinity)
                .disabled(isStarting)
                .opacity(isStarting ? 0.72 : 1)

            RecordingOptionsButton(isDisabled: isStarting)
                .disabled(isStarting)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(PanelIconButtonStyle(size: 24, backdropAdaptiveForeground: true))
            .disabled(isStarting)
            .opacity(isStarting ? 0.72 : 1)
            .help("Hide panel")
            .accessibilityIdentifier(AccessibilityIDs.Panel.closeButton)

            PrimaryRecordButton(kind: isStarting ? .loading : .record, action: onRecord)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(isStarting)
                .help(isStarting ? "Starting recording…" : "Record")
                .accessibilityIdentifier(AccessibilityIDs.Panel.recordButton)
        }
        .frame(height: 28)
    }
}
