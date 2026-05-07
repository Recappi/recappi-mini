import AppKit
import SwiftUI

private struct AboutAppInfo {
    let name: String
    let shortVersion: String
    let buildNumber: String
    let bundleIdentifier: String

    var versionDisplay: String {
        if shortVersion == buildNumber {
            return shortVersion
        }
        return "\(shortVersion) (\(buildNumber))"
    }

    static var current: AboutAppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return AboutAppInfo(
            name: (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? "Recappi Mini",
            shortVersion: (info["CFBundleShortVersionString"] as? String) ?? "Unknown",
            buildNumber: (info["CFBundleVersion"] as? String) ?? "Unknown",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.recappi.mini"
        )
    }
}

struct AboutRecappiMiniView: View {
    private let appInfo = AboutAppInfo.current
    @ObservedObject private var appUpdater = AppUpdater.shared

    private static let websiteURL = URL(string: "https://recordmeet.ing/")!

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                AboutHeroMark()

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appInfo.name)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Color.dtLabel)
                        Text("Meeting memory, right from your menu bar.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dtLabelSecondary)
                    }

                    VStack(spacing: 7) {
                        AboutInfoRow(title: "Version", value: appInfo.versionDisplay)
                        AboutInfoRow(title: "Bundle ID", value: appInfo.bundleIdentifier)
                        AboutInfoRow(title: "Website", value: Self.websiteURL.host ?? "recordmeet.ing")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 18)

            Divider()
                .overlay(Color.white.opacity(0.08))

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(Self.websiteURL)
                } label: {
                    Label("Website", systemImage: "safari")
                }
                .buttonStyle(AboutButtonStyle(primary: true))

                Button {
                    appUpdater.checkForUpdates()
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .buttonStyle(AboutButtonStyle())
                .disabled(!appUpdater.canCheckForUpdates)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .frame(width: 460)
        .background(
            ZStack(alignment: .topTrailing) {
                DT.recordingShell
                AboutBackgroundGrid()
                    .opacity(0.34)
            }
        )
        .preferredColorScheme(.dark)
        .containerBackground(DT.recordingShell, for: .window)
    }
}

private struct AboutHeroMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.14),
                            Color.white.opacity(0.045),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
                )

            VStack(spacing: 10) {
                LogoTile(size: 54)
                    .accessibilityHidden(true)

                HStack(spacing: 4) {
                    ForEach(0..<12, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(index.isMultiple(of: 3) ? DT.waveformLit : Color.white.opacity(0.48))
                            .frame(width: 3, height: CGFloat([10, 18, 14, 24, 12, 20, 28, 16, 22, 11, 17, 13][index]))
                    }
                }
                .frame(height: 30)

                HStack(spacing: 4) {
                    Circle()
                        .fill(DT.systemRed)
                        .frame(width: 6, height: 6)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white.opacity(0.28))
                        .frame(width: 46, height: 4)
                }
            }
        }
        .frame(width: 132, height: 154)
        .shadow(color: .black.opacity(0.24), radius: 18, y: 12)
    }
}

private struct AboutBackgroundGrid: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            ForEach(0..<9, id: \.self) { row in
                HStack(spacing: 7) {
                    ForEach(0..<10, id: \.self) { column in
                        RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                            .fill((row + column).isMultiple(of: 4) ? DT.waveformLit.opacity(0.34) : Color.white.opacity(0.13))
                            .frame(width: 3, height: 3)
                    }
                }
            }
        }
        .padding(.top, 18)
        .padding(.trailing, 18)
    }
}

private struct AboutInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.dtLabelTertiary)
                .frame(width: 58, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dtLabelSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AboutButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(primary ? Color.black.opacity(0.88) : Color.dtLabel)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .fill(background(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .stroke(primary ? Color.white.opacity(0.2) : Color.white.opacity(0.09), lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.84 : 1)
    }

    private func background(isPressed: Bool) -> some ShapeStyle {
        if primary {
            return AnyShapeStyle(LinearGradient(
                colors: [
                    DT.waveformLit.opacity(isPressed ? 0.82 : 1),
                    DT.accentGreenDeep.opacity(isPressed ? 0.82 : 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            ))
        }
        return AnyShapeStyle(LinearGradient(
            colors: [
                DT.recordingChip.opacity(isPressed ? 0.95 : 0.82),
                DT.recordingChip.opacity(isPressed ? 0.86 : 0.70),
            ],
            startPoint: .top,
            endPoint: .bottom
        ))
    }
}
