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
    @EnvironmentObject private var appUpdater: AppUpdater

    private static let websiteURL = URL(string: "https://recordmeet.ing/")!

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)

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
                .overlay(Palette.borderHairline)

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
        .containerBackground(Palette.surfaceWindow, for: .window)
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
            .foregroundStyle(primary ? Color.black.opacity(0.88) : Palette.labelPrimary)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .fill(primary ? DT.waveformLit : Palette.controlFillHover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .strokeBorder(Palette.borderHairline, lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.84 : 1)
    }
}
