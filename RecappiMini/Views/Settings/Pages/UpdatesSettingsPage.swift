import AppKit
import SwiftUI

struct UpdatesSettingsPage: View {
    @EnvironmentObject private var appUpdater: AppUpdater

    private static let websiteURL = URL(string: "https://recordmeet.ing/")!

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    LogoTile(size: 52)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recappi Mini")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Palette.labelPrimary)
                        Text("Meeting memory, right from your menu bar.")
                            .font(.footnote)
                            .foregroundStyle(Palette.labelSecondary)
                    }
                }
                .padding(.vertical, 6)

                SettingsReadonlyRow(label: "Version", value: appVersionText)

                LabeledContent("Website") {
                    Link("recordmeet.ing", destination: Self.websiteURL)
                }

                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { appUpdater.automaticallyChecksForUpdates },
                        set: { appUpdater.setAutomaticallyChecksForUpdates($0) }
                    )
                )

                HStack {
                    Button("Check for Updates…") {
                        appUpdater.checkForUpdates()
                    }
                    .disabled(!appUpdater.canCheckForUpdates)

                    Button("About Recappi Mini") {
                        AppDelegate.shared.showAboutPanel()
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
    }

    private var appVersionText: String {
        let bundle = Bundle.main
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildNumber) {
        case let (shortVersion?, buildNumber?) where shortVersion != buildNumber:
            return "\(shortVersion) (\(buildNumber))"
        case let (shortVersion?, _):
            return shortVersion
        case let (_, buildNumber?):
            return buildNumber
        default:
            return "Unknown"
        }
    }
}
