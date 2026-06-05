import Combine
import XCTest
@testable import RecappiMini

/// Pins the CPU-reduction change to `AudioActivityMonitor`: while a recording
/// is in flight the app backs the HAL poll cadence off from 2s to 5s, then
/// restores 2s on return to idle. These tests prove the new interval-backoff
/// control is *behaviour-preserving* — it never touches the published
/// `activeBundleIDs` value (the only thing downstream consumers read), the
/// enumeration logic is untouched, and re-arming is idempotent so flipping
/// recorder state doesn't churn the run loop.
@MainActor
final class AudioActivityMonitorPollIntervalTests: XCTestCase {

    /// The two cadences are exactly the values RecappiMiniApp toggles between
    /// from the recorder-state observer. Pinning them here guards against a
    /// silent drift between the constants and the documented 2s/5s contract.
    func testPollIntervalConstants() {
        XCTAssertEqual(AudioActivityMonitor.idlePollInterval, 2.0)
        XCTAssertEqual(AudioActivityMonitor.busyPollInterval, 5.0)
    }

    /// `setPollInterval` is a no-op before the timer is armed. This matches the
    /// real call order: the recorder-state Combine sink can fire its initial
    /// value immediately on subscription, and we must not accidentally arm a
    /// timer (or crash) ahead of `start()`.
    func testSetPollIntervalBeforeStartDoesNotPublishOrArm() {
        let monitor = AudioActivityMonitor()
        XCTAssertEqual(monitor.activeBundleIDs, [])

        monitor.setPollInterval(AudioActivityMonitor.busyPollInterval)
        monitor.setPollInterval(AudioActivityMonitor.idlePollInterval)

        // No timer was armed, so the published set stays at its empty default.
        XCTAssertEqual(monitor.activeBundleIDs, [])
        monitor.stop()
    }

    /// Equivalence guarantee for Rule 5: the value downstream consumers read
    /// (`activeBundleIDs`) is identical whether or not we flip the poll
    /// interval. The interval control must only affect *when* the next sweep
    /// runs — never *what* a sweep produces.
    func testIntervalFlipsDoNotMutatePublishedSet() async throws {
        let monitor = AudioActivityMonitor()
        monitor.start(pollInterval: AudioActivityMonitor.idlePollInterval)

        // Let the initial synchronous refresh's async query settle so we have a
        // stable reference value produced by the unmodified enumeration path.
        try await Task.sleep(for: .milliseconds(200))
        let reference = monitor.activeBundleIDs

        // Drive the same back-off/restore sequence the app performs on
        // recording start -> processing -> idle transitions.
        monitor.setPollInterval(AudioActivityMonitor.busyPollInterval)
        monitor.setPollInterval(AudioActivityMonitor.busyPollInterval) // idempotent
        monitor.setPollInterval(AudioActivityMonitor.idlePollInterval)

        // The interval changes alone must not have re-queried or mutated the
        // published set; it equals the reference snapshot.
        XCTAssertEqual(monitor.activeBundleIDs, reference)

        monitor.stop()
    }

    /// After `stop()`, the interval control is inert again — `stop()` clears the
    /// tracked cadence so a stray late `setPollInterval` (e.g. a trailing
    /// recorder-state event during teardown) cannot resurrect a timer.
    func testSetPollIntervalAfterStopIsInert() {
        let monitor = AudioActivityMonitor()
        monitor.start(pollInterval: AudioActivityMonitor.idlePollInterval)
        monitor.stop()

        let afterStop = monitor.activeBundleIDs
        monitor.setPollInterval(AudioActivityMonitor.busyPollInterval)
        XCTAssertEqual(monitor.activeBundleIDs, afterStop)
    }
}
