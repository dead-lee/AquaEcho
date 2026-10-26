import XCTest
@testable import AquaEchoCore

final class WatchActivityStateTests: XCTestCase {
    func testInactiveCannotSendStart() {
        let state = WatchActivityState()
        XCTAssertFalse(state.canSendStart)
    }

    func testInactivePreservesStartedUntilReset() {
        var state = WatchActivityState()
        state.setActive(true)
        XCTAssertTrue(state.canSendStart)
        state.markStarted()
        XCTAssertTrue(state.started)
        state.setActive(false)
        XCTAssertFalse(state.canSendStart)
        XCTAssertTrue(state.started, "中途 inactive 不应清除已 started")
        state.resetStarted()
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
