import AppKit
import SwiftUI

/// Source picker — SwiftUI pill trigger, native NSMenu for the dropdown.
/// Building our own popup never matched the system menu's chrome; using
/// `NSMenu.popUp()` gives real macOS styling (material, hover, keyboard
/// nav) without fighting AppKit.
struct AudioSourcePill: View {
    @ObservedObject var recorder: AudioRecorder
    @State private var anchor: NSView?
    @State private var hovered = false

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 6) {
                if let app = recorder.selectedApp, let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text(currentLabel)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.dtLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.dtLabelSecondary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .fill(DT.recordingChip.opacity(hovered ? 1.0 : 0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: DT.R.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DT.ease(0.12), value: hovered)
        .accessibilityIdentifier(AccessibilityIDs.Panel.audioSourcePicker)
        .background {
            // No explicit frame — the anchor NSView fills the pill so
            // anchor.convert(bounds, to: nil) returns the pill's real
            // window-space frame. A 0×0 frame would collapse to the
            // center and we'd pop the menu 90pt to the right.
            MenuAnchorView { anchor = $0 }
        }
    }

    private var currentLabel: String {
        recorder.selectedApp?.name ?? "All system audio"
    }

    @MainActor
    private func showMenu() {
        guard let anchor, let window = anchor.window else { return }
        recorder.refreshAppsFromWorkspaceSnapshot()
        let menu = buildMenu()
        let origin = menuPopUpLocation(for: menu, anchor: anchor, window: window)
        menu.popUp(positioning: nil, at: origin, in: nil)
        Task {
            await recorder.refreshApps(seedFromWorkspace: false)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.appearance = anchor?.window?.effectiveAppearance
        menu.autoenablesItems = true

        menu.addItem(menuItem(
            title: "All system audio",
            image: NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil),
            app: nil
        ))

        let activeApps = recorder.runningApps.filter { $0.isActive }
        if !activeApps.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Now Playing"))
            for app in activeApps { menu.addItem(menuItem(title: app.name, image: app.icon, app: app)) }
        }

        let grouped = Dictionary(grouping: recorder.runningApps.filter { !$0.isActive }, by: \.bucket)
        for (bucket, label) in [
            (AudioApp.Bucket.meeting, "Meeting apps"),
            (.browser, "Browsers"),
            (.other, "Other apps"),
        ] {
            guard let apps = grouped[bucket], !apps.isEmpty else { continue }
            menu.addItem(.separator())
            menu.addItem(sectionHeader(label))
            for app in apps { menu.addItem(menuItem(title: app.name, image: app.icon, app: app)) }
        }
        return menu
    }

    private func menuItem(title: String, image: NSImage?, app: AudioApp?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sleeve = MenuClosure { [recorder] in recorder.selectApp(app) }
        item.representedObject = sleeve
        item.target = sleeve
        item.action = #selector(MenuClosure.invoke)
        if let image {
            image.size = NSSize(width: 16, height: 16)
            item.image = image
        }
        item.state = (app?.id == recorder.selectedApp?.id) ? .on : .off
        return item
    }

    private func sectionHeader(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 0.6,
            ]
        )
        return item
    }

    private func menuPopUpLocation(for menu: NSMenu, anchor: NSView, window: NSWindow) -> CGPoint {
        let anchorBoundsInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorFrameOnScreen = window.convertToScreen(anchorBoundsInWindow)
        let screen = window.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        let menuSize = menu.size
        let inset: CGFloat = 8

        var location = CGPoint(
            x: anchorFrameOnScreen.minX,
            y: anchorFrameOnScreen.minY - 4
        )
        location.x = min(
            max(location.x, visibleFrame.minX + inset),
            max(visibleFrame.minX + inset, visibleFrame.maxX - menuSize.width - inset)
        )
        location.y = min(
            max(location.y, visibleFrame.minY + menuSize.height + inset),
            visibleFrame.maxY - inset
        )
        return location
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let onUpdate: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onUpdate(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onUpdate(nsView) }
    }
}

private final class MenuClosure: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
