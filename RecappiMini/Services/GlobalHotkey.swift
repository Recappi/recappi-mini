import Carbon.HIToolbox
import AppKit

// Carbon's C event handler is a function pointer, so it can't capture Swift state.
// We route it through a module-level storage slot that the @MainActor owner writes to.
nonisolated(unsafe) private var globalHotkeyHandler: (@Sendable () -> Void)?

/// Registers a system-wide hotkey via Carbon. Works regardless of which app has focus
/// and does not require Accessibility permission (unlike NSEvent global monitors).
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private var hotKeyRef: EventHotKeyRef?

    private init() {}

    /// Installs Cmd+Shift+R. Replaces any previously set handler.
    /// Safe to call multiple times: only registers the Carbon hotkey once.
    func installToggleRecording(handler: @escaping @Sendable () -> Void) {
        globalHotkeyHandler = handler
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                globalHotkeyHandler?()
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )

        let keyCode = UInt32(kVK_ANSI_R)
        let modifiers = UInt32(cmdKey | shiftKey)
        let hotKeyID = EventHotKeyID(signature: 0x52454341 /* 'RECA' */, id: 1)
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
