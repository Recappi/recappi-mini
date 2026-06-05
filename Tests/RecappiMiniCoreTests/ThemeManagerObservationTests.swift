import Combine
import Foundation
import XCTest
@testable import RecappiMini

/// Proves the CPU-reduction change in `ThemeManager.startObserving()` is
/// behavior-preserving for the theme path while no longer waking on unrelated
/// config writes.
///
/// The manager used to sink on `AppConfig.shared.objectWillChange`, which fires
/// on *every* `@Published` / `@AppStorage` mutation. It now observes only the
/// persisted `"appTheme"` defaults key via KVO
/// (`UserDefaults.standard.publisher(for: \.appTheme)`) and rebuilds the
/// `AppTheme` from the raw string. These tests pin the two guarantees that
/// matters:
///   1. EQUIVALENCE — the new observation source still yields the same
///      `AppTheme` that `AppConfig.theme` (the old `apply` argument) would.
///   2. SCOPE — a write to an unrelated defaults key produces no emission, so
///      mic-toggle / caption-pref churn during recording no longer schedules
///      any work on the main run loop.
final class ThemeManagerObservationTests: XCTestCase {
    private let themeKey = "appTheme"
    private let unrelatedKey = "recordingIncludeMicrophoneAudio"

    private var savedTheme: Any?
    private var savedUnrelated: Any?
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        // Snapshot so we restore the user's real defaults after the test.
        savedTheme = UserDefaults.standard.object(forKey: themeKey)
        savedUnrelated = UserDefaults.standard.object(forKey: unrelatedKey)
    }

    override func tearDown() {
        cancellables.removeAll()
        restore(savedTheme, forKey: themeKey)
        restore(savedUnrelated, forKey: unrelatedKey)
        super.tearDown()
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The `@objc dynamic` accessor that the KVO publisher keys off must read
    /// back exactly what `@AppStorage("appTheme")` persisted: the enum raw
    /// value. This is the equivalence link between the new source and the old
    /// `AppConfig.theme` read.
    func testAppThemeAccessorReflectsPersistedRawValueForEveryCase() {
        for theme in AppTheme.allCases {
            UserDefaults.standard.set(theme.rawValue, forKey: themeKey)

            let raw = UserDefaults.standard.appTheme
            XCTAssertEqual(raw, theme.rawValue)
            // The exact reconstruction the production pipeline performs.
            XCTAssertEqual(raw.flatMap(AppTheme.init(rawValue:)), theme)
        }
    }

    /// Mirrors the production pipeline's `compactMap`: a cleared or garbage raw
    /// value must decode to `nil` so the subscriber ignores it and the
    /// previously-applied theme stays in effect.
    func testUnparseableOrClearedRawValueDecodesToNil() {
        UserDefaults.standard.set("not-a-theme", forKey: themeKey)
        XCTAssertNil(UserDefaults.standard.appTheme.flatMap(AppTheme.init(rawValue:)))

        UserDefaults.standard.removeObject(forKey: themeKey)
        XCTAssertNil(UserDefaults.standard.appTheme.flatMap(AppTheme.init(rawValue:)))
    }

    /// EQUIVALENCE: the production publisher chain
    /// (`publisher(for: \.appTheme)` -> decode -> `removeDuplicates`) delivers
    /// the same sequence of `AppTheme` values that the old code derived from
    /// `AppConfig.theme`, in order, with duplicates collapsed.
    func testPublisherEmitsDecodedThemeOnAppThemeWrites() {
        // Start from a known value so the first change below is observable.
        UserDefaults.standard.set(AppTheme.light.rawValue, forKey: themeKey)

        var received: [AppTheme] = []
        let expectation = expectation(description: "theme changes observed")
        expectation.expectedFulfillmentCount = 3

        UserDefaults.standard
            .publisher(for: \.appTheme)
            .dropFirst() // skip the initial KVO emission for the current value
            .compactMap { $0.flatMap(AppTheme.init(rawValue:)) }
            .removeDuplicates()
            .sink { theme in
                received.append(theme)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        UserDefaults.standard.set(AppTheme.dark.rawValue, forKey: themeKey)
        UserDefaults.standard.set(AppTheme.dark.rawValue, forKey: themeKey) // duplicate, collapsed
        UserDefaults.standard.set(AppTheme.system.rawValue, forKey: themeKey)
        UserDefaults.standard.set(AppTheme.light.rawValue, forKey: themeKey)

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(received, [.dark, .system, .light])
    }

    /// SCOPE / the actual CPU win: a write to a *different* defaults key must
    /// not drive the theme observation at all. Under the old
    /// `objectWillChange` sink this same write would have scheduled an
    /// `apply(...)`; now it is silent.
    func testUnrelatedDefaultsWriteDoesNotEmit() {
        UserDefaults.standard.set(AppTheme.light.rawValue, forKey: themeKey)

        var emissions = 0
        let noEmission = expectation(description: "no theme emission for unrelated key")
        noEmission.isInverted = true

        UserDefaults.standard
            .publisher(for: \.appTheme)
            .dropFirst() // ignore the initial current-value emission
            .sink { _ in
                emissions += 1
                noEmission.fulfill()
            }
            .store(in: &cancellables)

        // Churn the unrelated key the way a mic toggle would during recording.
        UserDefaults.standard.set(true, forKey: unrelatedKey)
        UserDefaults.standard.set(false, forKey: unrelatedKey)
        UserDefaults.standard.set(true, forKey: unrelatedKey)

        wait(for: [noEmission], timeout: 0.5)
        XCTAssertEqual(emissions, 0)
    }
}
