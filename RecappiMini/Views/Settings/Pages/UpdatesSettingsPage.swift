import SwiftUI

struct UpdatesSettingsPage: View {
    @EnvironmentObject private var appUpdater: AppUpdater

    private static let updateCheckDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Form {
            SettingsPageHeader(
                title: "Updates",
                subtitle: "Stay current with the latest Recappi Mini build, and see app identity at a glance.",
                systemImage: "arrow.down.circle",
                color: .indigo
            )

            Section {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { appUpdater.automaticallyChecksForUpdates },
                        set: { appUpdater.setAutomaticallyChecksForUpdates($0) }
                    )
                )

                Toggle(
                    "Automatically download updates",
                    isOn: Binding(
                        get: { appUpdater.automaticallyDownloadsUpdates },
                        set: { appUpdater.setAutomaticallyDownloadsUpdates($0) }
                    )
                )
                .disabled(!appUpdater.automaticallyChecksForUpdates)

                HStack {
                    Button("Check for Updates…") {
                        appUpdater.checkForUpdates()
                    }
                    .disabled(!appUpdater.canCheckForUpdates)
                    Spacer(minLength: 0)
                }
            }

            Section {
                SettingsReadonlyRow(label: "App", value: "Recappi Mini")
                SettingsReadonlyRow(label: "Version", value: appVersionText)
                SettingsReadonlyRow(label: "Last checked", value: lastUpdateCheckText)

                HStack {
                    Button("About Recappi Mini") {
                        AppDelegate.shared.showAboutPanel()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .formStyle(.grouped)
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

    private var lastUpdateCheckText: String {
        guard let date = appUpdater.lastUpdateCheckDate else { return "Not yet" }
        return Self.updateCheckDateFormatter.string(from: date)
    }
}
