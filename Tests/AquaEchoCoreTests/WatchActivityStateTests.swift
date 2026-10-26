import XCTest
@testable import AquaEchoCore

final class WatchActivityStateTests: XCTestCase {
    func testInactiveCannotSendStart() {
        let state = WatchActivityState()
        XCTAssertFalse(state.canSendStart)
    }

    func testActiveAllowsStartAndInactiveResetsAck() {
        var state = WatchActivityState()
        state.setActive(true)
        XCTAssertTrue(state.canSendStart)
        state.markStarted()
        XCTAssertTrue(state.started)
        state.setActive(false)
        XCTAssertFalse(state.canSendStart)
        XCTAssertFalse(state.started)
    }

    func testNewRunResetsStarted() {
        var state = WatchActivityState()
        state.setActive(true)
        state.markStarted()
        state.resetStarted()
        XCTAssertTrue(state.active)
        XCTAssertFalse(state.started)
    }
}
