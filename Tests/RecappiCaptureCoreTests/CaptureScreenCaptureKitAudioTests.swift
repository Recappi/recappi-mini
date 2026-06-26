import XCTest
@testable import RecappiCaptureCore

final class CaptureScreenCaptureKitAudioTests: XCTestCase {
    func testAudioConfigurationStaysTinyAndAudioOnly() {
        let config = CaptureScreenCaptureKitAudio.makeAudioConfiguration()

        XCTAssertTrue(config.capturesAudio)
        XCTAssertEqual(config.width, 2)
        XCTAssertEqual(config.height, 2)
        XCTAssertEqual(config.queueDepth, 1)
        XCTAssertEqual(config.sampleRate, 48_000)
        XCTAssertEqual(config.channelCount, 2)
        XCTAssertTrue(config.excludesCurrentProcessAudio)
    }
}
