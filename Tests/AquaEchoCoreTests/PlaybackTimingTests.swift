import XCTest
@testable import AquaEchoCore

final class PlaybackTimingTests: XCTestCase {
    func testNoPreRollAfterStart() {
        XCTAssertEqual(PlaybackTiming.preRollSeconds, 0)
    }
}
