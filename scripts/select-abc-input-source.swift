#!/usr/bin/env swift

import Carbon
import Foundation

// XCUITest keyboard events are sent by macOS testmanagerd. If the current
// selected input source is a third-party IME that is not enabled for
// testmanagerd, macOS can interrupt the run with an "Allow testmanagerd to
// enable ..." privacy prompt. Keep UI-test runs on a built-in keyboard layout.
let preferredInputSourceIDs = [
    "com.apple.keylayout.ABC",
    "com.apple.keylayout.US",
]

func selectInputSource(withID id: String) -> Bool {
    let query = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard
        let unmanagedList = TISCreateInputSourceList(query, false),
        let sources = unmanagedList.takeRetainedValue() as? [TISInputSource],
        let source = sources.first
    else {
        return false
    }

    let status = TISSelectInputSource(source)
    if status == noErr {
        print("Selected keyboard input source: \(id)")
        return true
    }

    fputs("Failed to select keyboard input source \(id): \(status)\n", stderr)
    return false
}

for id in preferredInputSourceIDs where selectInputSource(withID: id) {
    exit(0)
}

fputs("Unable to select a built-in keyboard input source.\n", stderr)
exit(1)
