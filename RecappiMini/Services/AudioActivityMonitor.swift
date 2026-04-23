import AppKit
import CoreAudio
import Foundation

/// Polls CoreAudio's HAL process list to find which apps are currently
/// producing audio output. The macOS 14.4+ process-object API exposes
/// `kAudioProcessPropertyIsRunningOutput` per audio-emitting process, so
/// we don't need to open a probe stream or parse `ps` output.
@MainActor
final class AudioActivityMonitor: ObservableObject {
    /// Parent bundle IDs of apps currently outputting audio. Helpers are
    /// collapsed via BundleCollapser so Chrome shows up as `com.google.Chrome`
    /// instead of its renderer child.
    @Published private(set) var activeBundleIDs: Set<String> = []

    private var timer: Timer?

    /// Default 2s cadence — fast enough to feel responsive when a Zoom call
    /// starts, slow enough that the HAL query doesn't become a background tax.
    func start(pollInterval: TimeInterval = 2.0) {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let active = Self.queryActiveProcesses()
        if active != activeBundleIDs {
            activeBundleIDs = active
        }
    }

    private static func queryActiveProcesses() -> Set<String> {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &listAddr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &listAddr, 0, nil, &size, &ids) == noErr else {
            return []
        }

        var active: Set<String> = []
        for id in ids {
            guard isRunningOutput(id) else { continue }

            // Prefer HAL-supplied bundle ID (macOS 14.4+); fall back to the
            // PID → NSRunningApplication route since some system daemons and
            // CLI helpers don't expose CFBundleID to CoreAudio. CLI tools
            // (afplay, say → speechsynthesisd) resolve to nothing in either
            // path and are correctly skipped.
            var resolved: String? = bundleID(for: id)
            if resolved?.isEmpty ?? true {
                resolved = pid(for: id).flatMap { pid in
                    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                }
            }
            guard let bundleID = resolved, !bundleID.isEmpty else { continue }
            active.insert(BundleCollapser.parent(of: bundleID))
        }
        return active
    }

    private static func pid(for id: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var size: UInt32 = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, value > 0 else {
            return nil
        }
        return value
    }

    private static func isRunningOutput(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private static func bundleID(for id: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        var cfstr: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfstr) == noErr,
              let cf = cfstr?.takeRetainedValue() else {
            return nil
        }
        return cf as String
    }
}
