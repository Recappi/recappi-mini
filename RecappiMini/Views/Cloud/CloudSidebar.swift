import SwiftUI

struct CloudSidebarBillingSummary: View {
    let status: BillingStatus?
    let errorMessage: String?
    let isLoading: Bool
    let isOpeningBilling: Bool
    let onOpenBilling: () -> Void
    let onOpenPlans: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(planText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(planColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 7)
                .frame(minWidth: 54)
                .frame(height: 24)
                .background(
                    Capsule(style: .continuous)
                        .fill(planColor.opacity(0.10))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(planColor.opacity(0.16), lineWidth: 0.7)
                )

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 24)

            HStack(spacing: 14) {
                headerUsageMetric(
                    title: "Storage",
                    valueText: status?.storageUsageText ?? "Loading",
                    progress: status?.storageProgress ?? 0,
                    isOverLimit: status?.effectiveIsOverStorage ?? false
                )

                headerUsageMetric(
                    title: "Minutes",
                    valueText: status?.minutesUsageText ?? (errorMessage ?? "Loading"),
                    progress: status?.minutesProgress ?? 0,
                    isOverLimit: status?.effectiveIsOverMinutes ?? false
                )
            }
            .redacted(reason: status == nil && isLoading ? .placeholder : [])

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 24)

            Button {
                onOpenBilling()
            } label: {
                if isOpeningBilling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Opening…")
                    }
                } else {
                    Label("Billing", systemImage: "creditcard")
                }
            }
            .buttonStyle(HeaderGlassButtonStyle())
            .frame(width: 82)
            .disabled(isOpeningBilling)
            .accessibilityIdentifier(AccessibilityIDs.Cloud.billingButton)
        }
        .padding(.horizontal, 2)
        .frame(height: 34)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(subtitle)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.billingStatus)
    }

    private func headerUsageMetric(title: String, valueText: String, progress: Double, isOverLimit: Bool) -> some View {
        let clampedProgress = max(0, min(1, progress))

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(isOverLimit ? DT.systemOrange.opacity(0.92) : Color.dtLabelTertiary)
                    .tracking(0.18)

                Text(valueText)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(isOverLimit ? DT.systemOrange : Color.dtLabelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.11))
                Capsule(style: .continuous)
                    .fill(isOverLimit ? DT.systemOrange : DT.waveformLit)
                    .frame(width: 132 * clampedProgress)
            }
            .frame(width: 132, height: 3)
        }
        .frame(width: 142, alignment: .leading)
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
        .frame(width: 124)
    }
}

struct CloudRecordingDateSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.dtLabelTertiary)
                .tracking(0.32)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.dtLabelQuaternary)
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) recordings")
    }
}

struct CloudRecordingRow: View {
    let recording: CloudRecording
    let latestJobStatus: RemoteJobStatus?
    let isSelected: Bool
    let isNowPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                // Source icon column. peng-xiao `26485a7a` asked the icon
                // to "just be bigger" rather than padded inside a smaller
                // visual box, and to vertically anchor the row (not float
                // beside the title). 24pt -> 30pt + center alignment puts
                // the icon between the two metadata rows so it visually
                // covers the full row height; the previous `.top` align
                // + `.padding(.top, 1)` decorative offset is no longer
                // needed.
                CloudSourceIcon(recording: recording, size: 30)

                VStack(alignment: .leading, spacing: 4) {
                    // Row 1: title + status chip. Title is the primary
                    // affordance, chip sits trailing as the status read.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if isNowPlaying {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(DT.waveformLit)
                                .frame(width: 12)
                                .accessibilityLabel("Now playing")
                        }

                        Text(recording.presentationTitle)
                            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(Color.dtLabel)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 0)

                        CloudStatusChip(status: recording.status, latestJobStatus: latestJobStatus)
                    }

                    // Row 2: single metadata bar - `source · time · duration`.
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
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? DT.recordingChip.opacity(0.82) : Color.white.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? DT.statusReady.opacity(0.34) : Color.white.opacity(0.045), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.recordingRowPrefix + recording.id)
    }
}
