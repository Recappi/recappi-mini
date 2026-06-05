import AppKit
import CoreAudio
import Foundation

private actor AudioActivityQueryService {
    func activeBundleIDs() -> Set<String> {
        Self.queryActiveProcesses()
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
            // PID -> NSRunningApplication route since some system daemons and
            // CLI helpers don't expose CFBundleID to CoreAudio. CLI tools
            // (afplay, say -> speechsynthesisd) resolve to nothing in either
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
    private var refreshTask: Task<Void, Never>?
    private let queryService = AudioActivityQueryService()

    /// The cadence the timer is currently scheduled at. Tracked so a
    /// back-off request that matches the live interval is a cheap no-op
    /// instead of tearing down and rebuilding the timer on every recorder
    /// state transition.
    private var currentPollInterval: TimeInterval?

    /// Default idle cadence — fast enough to feel responsive when a Zoom
    /// call starts, slow enough that the HAL query doesn't become a
    /// background tax.
    static let idlePollInterval: TimeInterval = 2.0

    /// Relaxed cadence used while a recording is in flight. The HAL query's
    /// only idle-state consumer (the auto-prompt) is dormant then, and the
    /// detected-meeting auto-stop loop still reads the activity set — just a
    /// few seconds staler — so we keep polling but lighten the per-tick HAL
    /// syscall tax instead of pausing outright.
    static let busyPollInterval: TimeInterval = 5.0

    func start(pollInterval: TimeInterval = idlePollInterval) {
        refresh()
        schedule(pollInterval: pollInterval)
    }

    /// Adjusts the poll cadence in place without disturbing the published
    /// `activeBundleIDs` value or the enumeration logic. Re-arms the timer
    /// only when the interval actually changes, so flipping recorder state
    /// repeatedly doesn't churn the run loop. No-op until `start()` has armed
    /// the timer.
    func setPollInterval(_ pollInterval: TimeInterval) {
        guard timer != nil else { return }
        guard currentPollInterval != pollInterval else { return }
        schedule(pollInterval: pollInterval)
    }

    private func schedule(pollInterval: TimeInterval) {
        timer?.invalidate()
        currentPollInterval = pollInterval
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = min(0.5, pollInterval * 0.25)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        currentPollInterval = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self, queryService] in
            let active = await queryService.activeBundleIDs()
            guard !Task.isCancelled else {
                await MainActor.run {
                    self?.refreshTask = nil
                }
                return
            }
            await MainActor.run {
                guard let self else { return }
                self.refreshTask = nil
                if active != self.activeBundleIDs {
                    self.activeBundleIDs = active
                }
            }
        }
    }
}
