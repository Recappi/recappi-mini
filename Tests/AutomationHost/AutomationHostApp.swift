import SwiftUI

@main
struct RecappiMiniAutomationHostApp: App {
    var body: some Scene {
        WindowGroup("Recappi Mini Automation Host") {
            VStack(spacing: 12) {
                Text("Recappi Mini Automation Host")
                    .font(.headline)
                Text("This host exists only so XCUITest has a stable target.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(minWidth: 360, minHeight: 180)
        }
    }
}
