import SwiftUI

@main
struct RecappiMiniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private let recorder = AudioRecorder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80))

        let contentView = RecordingPanel(recorder: recorder) { folderURL in
            NSWorkspace.shared.open(folderURL)
        }

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hostingView
        FloatingPanelController.positionAtTopRight(panel, width: 300, height: 80)
        panel.orderFrontRegardless()

        self.panel = panel

        // Scan for meeting apps
        Task {
            await recorder.refreshApps()
        }
    }
}
