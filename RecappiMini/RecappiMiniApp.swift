import SwiftUI

@main
struct RecappiMiniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // MenuBar icon for show/hide and quit
        MenuBarExtra("Recappi Mini", systemImage: "waveform.circle.fill") {
            // Same shortcut as the global hotkey — informational; Carbon catches the keypress first.
            Button("Toggle Recording") {
                appDelegate.toggleRecordingFromMenu()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Show Panel") {
                appDelegate.showPanel()
            }
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    let recorder = AudioRecorder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 56))

        let contentView = RecordingPanel(recorder: recorder) { folderURL in
            NSWorkspace.shared.open(folderURL)
        }

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hostingView
        FloatingPanelController.restoreOrTopRight(panel, width: 280, height: 56)
        panel.orderFrontRegardless()

        self.panel = panel

        Task {
            await recorder.refreshApps()
        }

        // Global Cmd+Shift+R to toggle recording from anywhere.
        GlobalHotkey.shared.installToggleRecording { [weak self] in
            Task { @MainActor in
                self?.toggleRecordingFromMenu()
            }
        }
    }

    func showPanel() {
        panel?.orderFrontRegardless()
    }

    func toggleRecordingFromMenu() {
        panel?.orderFrontRegardless()
        recorder.toggleRecording()
    }
}
