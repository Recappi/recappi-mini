import AppKit
import CoreImage
import Foundation
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// Watches the screen content under a floating panel and decides whether
/// the panel should use a light or dark chrome to stay legible. The
/// shipping HUD's light theme leans on translucent vibrancy materials,
/// which mix with whatever is behind the panel — sitting on a dark
/// surface (a dark app window, dark wallpaper, terminal) bleeds the
/// pill chrome into a muddy grey. This observer samples the backdrop
/// luminance, hysteresis-filters the result, and publishes a single
/// `prefersDarkChrome` flag that the panel chrome bindings can read.
///
/// Sampling uses the legacy `CGWindowListCreateImage` API (still works
/// on macOS 14+) restricted to windows below the panel's own window
/// number. We already hold Screen Recording entitlement for audio
/// capture via ScreenCaptureKit, so no new permission is requested. If
/// sampling fails for any reason (permission revoked, capture returned
/// nothing, image processing error) the observer falls back to dark
/// chrome — the previous "light chrome over dark backdrop" failure mode
/// peng-xiao flagged should never re-emerge.
@MainActor
final class BackdropLuminanceObserver: ObservableObject {
    /// `true` when the sampled backdrop is dark enough that the panel
    /// should switch to a dark chrome. SwiftUI views read this through
    /// the published binding to flip materials with a smooth animation.
    @Published private(set) var prefersDarkChrome: Bool = true

    /// Luminance threshold (rec. 709) below which we consider the
    /// backdrop "dark". 0.55 puts the cutover near a mid-grey so any
    /// noticeably dark surface (saturated colors / dark images / dark
    /// terminals) trips dark chrome; light wallpapers and white app
    /// windows stay in light chrome.
    private let darknessThreshold: Double = 0.55

    /// Hysteresis window — a new luminance verdict only wins after it
    /// has been consistent for at least this long. Prevents flickering
    /// when a panel sits on the edge of a window and the average wobbles
    /// across the threshold every tick. Measured in wall-clock time, so
    /// it must stay >= `sampleInterval` to still require a *second*
    /// confirming sample before committing a flip; at the 2.0 s sampling
    /// rate that means a flip needs two consecutive matching ticks, which
    /// keeps the original "be consistent across samples" anti-flicker
    /// guarantee.
    private let hysteresisInterval: TimeInterval = 2.0

    /// Heartbeat re-sample cadence. The panel is anchored (top-right) and
    /// doesn't move on its own, so the verdict only needs to change when
    /// the backdrop *content* shifts under a static panel (a video plays,
    /// another window repaints). User-driven changes (dragging the panel,
    /// screen/space changes) are handled event-driven below, so this
    /// heartbeat can be slow. A fixed-2 Hz poll was the dominant CPU cost
    /// during recording — each tick runs a full ScreenCaptureKit
    /// roundtrip, which also contends with the audio-capture SCStream.
    private let sampleInterval: TimeInterval = 2.0

    /// Pending verdict that hasn't yet survived the hysteresis window.
    private var pendingVerdict: Bool?
    private var pendingVerdictStart: Date?

    private var samplingTimer: Timer?
    private weak var trackedWindow: NSWindow?
    private var samplingInFlight: Bool = false

    /// Event-driven re-sample tokens. These fire an immediate sample on the
    /// only moments the backdrop genuinely changes under user action, which
    /// is what lets the heartbeat above stay slow without feeling laggy.
    private var windowMoveToken: NSObjectProtocol?
    private var screenParamsToken: NSObjectProtocol?
    private var spaceChangeToken: NSObjectProtocol?

    /// Mirrors `FloatingPanel.applyAdaptiveAppearance`: in a dark system
    /// appearance the panel inherits the host appearance and the backdrop
    /// verdict is discarded, so sampling is pure wasted work.
    private var systemUsesDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    var diagnosticsSamplingState: String {
        if UITestModeConfiguration.shared.forceAdaptiveDarkChromeForTesting {
            return "forced"
        }
        guard trackedWindow != nil, samplingTimer != nil else {
            return "inactive"
        }
        return systemUsesDarkAppearance ? "inactive:system_dark" : "active"
    }

    var diagnosticsChromeMode: String {
        if systemUsesDarkAppearance {
            return "system_dark"
        }
        return prefersDarkChrome ? "dark" : "light"
    }

    /// Start sampling the backdrop beneath the given window. Idempotent;
    /// calling again with the same window is a no-op.
    ///
    /// In UI test mode with `RECAPPI_TEST_FORCE_ADAPTIVE_DARK_CHROME=1`
    /// we skip the sampling timer entirely and pin `prefersDarkChrome`
    /// so screenshot fixtures can capture dark-chrome rendering without
    /// physically dragging the panel over a dark window.
    func attach(to window: NSWindow) {
        if UITestModeConfiguration.shared.forceAdaptiveDarkChromeForTesting {
            trackedWindow = window
            samplingTimer?.invalidate()
            samplingTimer = nil
            prefersDarkChrome = true
            return
        }
        if trackedWindow === window, samplingTimer != nil { return }
        trackedWindow = window
        startTimer()
    }

    func detach() {
        samplingTimer?.invalidate()
        samplingTimer = nil
        removeEventObservers()
        trackedWindow = nil
        pendingVerdict = nil
        pendingVerdictStart = nil
    }

    private func startTimer() {
        samplingTimer?.invalidate()
        installEventObservers()
        // Sample once immediately so the chrome doesn't briefly flash
        // the default before the first tick lands.
        sampleNow()
        samplingTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleNow()
            }
        }
    }

    /// Subscribe to the events that actually change the backdrop so the
    /// heartbeat can run slowly. Each fires a coalesced `sampleNow()`
    /// (which no-ops while a sample is in flight or in dark appearance).
    private func installEventObservers() {
        removeEventObservers()
        let center = NotificationCenter.default
        if let window = trackedWindow {
            windowMoveToken = center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.sampleNow() }
            }
        }
        screenParamsToken = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleNow() }
        }
        spaceChangeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleNow() }
        }
    }

    private func removeEventObservers() {
        if let token = windowMoveToken {
            NotificationCenter.default.removeObserver(token)
            windowMoveToken = nil
        }
        if let token = screenParamsToken {
            NotificationCenter.default.removeObserver(token)
            screenParamsToken = nil
        }
        if let token = spaceChangeToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            spaceChangeToken = nil
        }
    }

    private func sampleNow() {
        guard let window = trackedWindow, window.isVisible else { return }
        // Skip the ScreenCaptureKit roundtrip when the verdict won't be
        // used. The slow heartbeat keeps ticking, so switching back to a
        // light system appearance self-corrects within one interval.
        guard !systemUsesDarkAppearance else { return }
        guard !samplingInFlight else { return }

        let frame = window.frame
        guard frame.width > 4, frame.height > 4 else { return }
        let windowNumber = CGWindowID(window.windowNumber)
        guard let display = window.screen else { return }
        let displayFrame = display.frame
        let threshold = darknessThreshold

        samplingInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            let verdict = await Self.sampleBackdropVerdict(
                windowFrame: frame,
                excludingWindowID: windowNumber,
                displayFrame: displayFrame,
                threshold: threshold
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.samplingInFlight = false
                guard self.trackedWindow?.windowNumber == Int(windowNumber) else { return }
                self.applyVerdict(verdict)
            }
        }
    }

    /// Performs the ScreenCaptureKit roundtrip off the main actor. Always
    /// returns a verdict — falls back to `true` (dark chrome) on any
    /// error, since that's the safe default per peng-xiao's complaint.
    private nonisolated static func sampleBackdropVerdict(
        windowFrame: CGRect,
        excludingWindowID: CGWindowID,
        displayFrame: CGRect,
        threshold: Double
    ) async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: { $0.frame.intersects(windowFrame) }) ?? content.displays.first else {
                return true
            }
            let excludedWindows = content.windows.filter { $0.windowID == excludingWindowID }
            let filter = SCContentFilter(
                display: display,
                excludingWindows: excludedWindows
            )

            let configuration = SCStreamConfiguration()
            // Translate Cocoa screen-space (y from bottom) to SCStream's
            // flipped display-local space (y from top of `display.frame`).
            let displayLocalX = windowFrame.origin.x - displayFrame.origin.x
            let displayLocalY = (displayFrame.maxY - windowFrame.maxY)
            configuration.sourceRect = CGRect(
                x: displayLocalX,
                y: displayLocalY,
                width: windowFrame.width,
                height: windowFrame.height
            )
            configuration.width = max(8, Int(windowFrame.width / 8))
            configuration.height = max(8, Int(windowFrame.height / 8))
            configuration.scalesToFit = true
            configuration.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            let context = CIContext(options: [.useSoftwareRenderer: false])
            let luminance = averageLuminance(of: cgImage, using: context)
            return luminance < threshold
        } catch {
            return true
        }
    }

    private nonisolated static func averageLuminance(of cgImage: CGImage, using context: CIContext) -> Double {
        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        guard let filter = CIFilter(name: "CIAreaAverage") else { return 0.5 }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: "inputExtent")
        guard let output = filter.outputImage else { return 0.5 }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let r = Double(bitmap[0]) / 255.0
        let g = Double(bitmap[1]) / 255.0
        let b = Double(bitmap[2]) / 255.0
        // rec. 709 luma — what the eye reads as "brightness". Pure RGB
        // average overweights blue/red surfaces; this puts the threshold
        // where humans actually see the transition.
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func applyVerdict(_ newVerdict: Bool) {
        if newVerdict == prefersDarkChrome {
            // Already in the right state; drop any pending opposite verdict.
            pendingVerdict = nil
            pendingVerdictStart = nil
            return
        }

        let now = Date()
        if pendingVerdict == newVerdict, let start = pendingVerdictStart {
            if now.timeIntervalSince(start) >= hysteresisInterval {
                prefersDarkChrome = newVerdict
                pendingVerdict = nil
                pendingVerdictStart = nil
            }
            return
        }

        pendingVerdict = newVerdict
        pendingVerdictStart = now
    }
}
