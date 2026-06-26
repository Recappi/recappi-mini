import XCTest
@testable import RecappiCaptureCore

final class CaptureSourceCatalogTests: XCTestCase {
    func testBuildsStableSystemAndAppSources() {
        let sources = CaptureSourceCatalog.sources(
            from: [
                CaptureSourceApplication(bundleID: "com.zoom.us", name: "zoom.us"),
                CaptureSourceApplication(bundleID: "com.google.Chrome.helper", name: "Google Chrome Helper"),
                CaptureSourceApplication(bundleID: "com.google.Chrome", name: "Google Chrome"),
                CaptureSourceApplication(bundleID: "com.recappi.mini", name: "Recappi Mini"),
                CaptureSourceApplication(bundleID: "com.apple.finder", name: "Finder"),
                CaptureSourceApplication(bundleID: "com.apple.Safari", name: "Safari"),
            ],
            selfBundleID: "com.recappi.mini"
        )

        XCTAssertEqual(sources.first, CaptureSourceCatalog.systemSource)
        XCTAssertEqual(sources.map(\.bundleID), [nil, "com.google.Chrome", "com.apple.Safari", "com.zoom.us"])
        XCTAssertEqual(sources.map(\.id), ["system", "app:com.google.Chrome", "app:com.apple.Safari", "app:com.zoom.us"])
    }

    func testCanReturnOnlyApplicationSources() {
        let sources = CaptureSourceCatalog.sources(
            from: [
                CaptureSourceApplication(bundleID: "company.thebrowser.arc.helper", name: "Arc Helper"),
            ],
            selfBundleID: "com.recappi.mini",
            includeSystemSource: false
        )

        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.id, "app:company.thebrowser.Browser")
        XCTAssertEqual(sources.first?.label, "Arc")
        XCTAssertEqual(sources.first?.bundleID, "company.thebrowser.Browser")
    }

    func testInclusionRulesSkipSelfAndNonNotableAppleApps() {
        XCTAssertFalse(CaptureSourceCatalog.shouldInclude(bundleID: "com.recappi.mini", selfBundleID: "com.recappi.mini"))
        XCTAssertFalse(CaptureSourceCatalog.shouldInclude(bundleID: "com.apple.finder", selfBundleID: "com.recappi.mini"))
        XCTAssertTrue(CaptureSourceCatalog.shouldInclude(bundleID: "com.apple.Safari", selfBundleID: "com.recappi.mini"))
        XCTAssertTrue(CaptureSourceCatalog.shouldInclude(bundleID: "us.zoom.xos", selfBundleID: "com.recappi.mini"))
    }
}
