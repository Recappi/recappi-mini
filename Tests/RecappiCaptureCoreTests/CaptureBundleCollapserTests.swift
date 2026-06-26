import XCTest
@testable import RecappiCaptureCore

final class CaptureBundleCollapserTests: XCTestCase {
    func testCollapsesChromiumHelperBundlesToUserVisibleParent() {
        XCTAssertEqual(
            CaptureBundleCollapser.parent(of: "com.google.Chrome.helper.Renderer"),
            "com.google.Chrome"
        )
        XCTAssertEqual(
            CaptureBundleCollapser.parent(of: "com.brave.Browser.Helper.GPU"),
            "com.brave.Browser"
        )
        XCTAssertEqual(
            CaptureBundleCollapser.parent(of: "com.operasoftware.Opera.Agent"),
            "com.operasoftware.Opera"
        )
    }

    func testCanonicalizesArcBundleAliases() {
        XCTAssertEqual(
            CaptureBundleCollapser.parent(of: "company.thebrowser.arc"),
            "company.thebrowser.Browser"
        )
        XCTAssertEqual(
            CaptureBundleCollapser.parent(of: "company.thebrowser.Browser.helper.Renderer"),
            "company.thebrowser.Browser"
        )
    }

    func testMatchesHelperAudioToSelectedParentBundle() {
        XCTAssertTrue(
            CaptureBundleCollapser.matches(
                "company.thebrowser.Browser.helper.Renderer",
                selected: "company.thebrowser.Browser"
            )
        )
        XCTAssertTrue(
            CaptureBundleCollapser.matches(
                "com.google.Chrome.helper.GPU",
                selected: "com.google.Chrome"
            )
        )
        XCTAssertFalse(
            CaptureBundleCollapser.matches(
                "com.apple.Safari",
                selected: "com.google.Chrome"
            )
        )
    }

    func testBrowserNameLookupKeepsPickerLabelsUserVisible() {
        XCTAssertEqual(
            CaptureBundleCollapser.canonicalBrowserBundleID(for: "Arc Browser"),
            "company.thebrowser.Browser"
        )
        XCTAssertEqual(
            CaptureBundleCollapser.browserDisplayName(
                for: "company.thebrowser.Browser.helper.Renderer",
                fallback: "Arc Helper"
            ),
            "Arc"
        )
        XCTAssertEqual(
            CaptureBundleCollapser.browserDisplayName(
                for: "com.google.Chrome.helper.Renderer",
                fallback: "Google Chrome Helper"
            ),
            "Google Chrome"
        )
    }
}
