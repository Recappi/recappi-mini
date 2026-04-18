import SwiftUI

@main
struct RecappiMiniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Recappi Mini", systemImage: "waveform.circle.fill") {
            Button("Show Panel") {
                appDelegate.showPanel()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",", modifiers: [.command])
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        // Standalone Settings window — opened via ⌘, or the gear in the panel.
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private let recorder = AudioRecorder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 56))

        let contentView = RecordingPanel(recorder: recorder) { folderURL in
            NSWorkspace.shared.open(folderURL)
        }

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hostingView
        FloatingPanelController.positionAtTopRight(panel, width: 280, height: 56)
        panel.orderFrontRegardless()

        self.panel = panel

        Task {
            await recorder.refreshApps()
        }
    }

    func showPanel() {
        panel?.orderFrontRegardless()
    }
}
