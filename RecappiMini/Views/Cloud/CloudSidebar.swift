import SwiftUI

/// Compact vertical billing/quota card for the sidebar's top section.
/// Replaces the wide horizontal billing strip that used to sit in the
/// custom panel header.
struct CloudSidebarBillingSummaryCompact: View {
    let status: BillingStatus?
    let errorMessage: String?
    let isLoading: Bool
    let isOpeningBilling: Bool
    let onOpenBilling: () -> Void
    let onOpenPlans: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(planText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(planColor)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(planColor.opacity(0.12))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(planColor.opacity(0.18), lineWidth: 0.7)
                    )

                Spacer(minLength: 0)

                Button {
                    onOpenBilling()
                } label: {
                    if isOpeningBilling {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Opening…")
                        }
                    } else {
                        Label("Billing", systemImage: "creditcard")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isOpeningBilling)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.billingButton)
            }

            VStack(alignment: .leading, spacing: 8) {
                CloudLimitMeter(
                    title: "Storage",
                    valueText: status?.storageUsageText ?? "Loading",
                    progress: status?.storageProgress ?? 0,
                    isOverLimit: status?.effectiveIsOverStorage ?? false
                )
                CloudLimitMeter(
                    title: "Minutes",
                    valueText: status?.minutesUsageText ?? (errorMessage ?? "Loading"),
                    progress: status?.minutesProgress ?? 0,
                    isOverLimit: status?.effectiveIsOverMinutes ?? false
                )
            }
            .redacted(reason: status == nil && isLoading ? .placeholder : [])
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(subtitle)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.billingStatus)
    }

    private var planText: String {
        if let status {
            return status.tier.displayName
        }
        return isLoading ? "Loading…" : "Unavailable"
    }

    private var planColor: Color {
        if let status {
            return status.effectiveIsOverAnyLimit ? DT.systemOrange : DT.waveformLit
        }
        return isLoading ? Color.dtLabelSecondary : DT.systemOrange
    }

    private var subtitle: String {
        if let errorMessage {
            return errorMessage
        }
        if let status {
            if status.effectiveIsOverAnyLimit {
                return "Limit reached. Delete recordings or upgrade to continue."
            }
            return status.periodEndText.map { "Quota resets \($0)" } ?? "Current billing window"
        }
        return "Checking plan limits"
    }
}

struct CloudLimitMeter: View {
    let title: String
    let valueText: String
    let progress: Double
    let isOverLimit: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .tracking(0.3)
                Spacer(minLength: 0)
                Text(valueText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isOverLimit ? DT.systemOrange : Color.dtLabelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(isOverLimit ? DT.systemOrange : DT.waveformLit)
                        .frame(width: proxy.size.width * max(0, min(1, progress)))
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Sidebar list row content. List drives selection via `.tag()` — this
/// view stays purely visual so the system selection capsule provides the
/// dominant highlight. `isSelected` is retained only to thicken the
/// title weight, reinforcing the selected state without competing with
/// the list's own background.
struct CloudRecordingRow: View {
    let recording: CloudRecording
    let latestJobStatus: RemoteJobStatus?
    let isSelected: Bool
    let isNowPlaying: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            CloudSourceIcon(recording: recording, size: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if isNowPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(DT.waveformLit)
                            .frame(width: 12)
                            .accessibilityLabel("Now playing")
                    }

                    Text(recording.presentationTitle)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Color.dtLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    CloudStatusChip(status: recording.status, latestJobStatus: latestJobStatus)
                }

                HStack(spacing: 6) {
                    Text(recording.sourceLine)
                    Text("·")
                        .foregroundStyle(Color.dtLabelQuaternary)
                    Text(recording.listTimeText)
                    if let duration = recording.durationText {
                        Text("·")
                            .foregroundStyle(Color.dtLabelQuaternary)
                        Text(duration)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Color.dtLabelTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityIdentifier(AccessibilityIDs.Cloud.recordingRowPrefix + recording.id)
    }
}
