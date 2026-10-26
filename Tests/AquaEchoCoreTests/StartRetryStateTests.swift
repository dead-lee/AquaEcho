import XCTest
@testable import AquaEchoCore

final class StartRetryStateTests: XCTestCase {
    func testOnlyFailedSendCreatesPending() {
        var state = StartRetryState()
        state.record(sent: false)
        XCTAssertTrue(state.pending)
        state.record(sent: true)
        XCTAssertFalse(state.pending)
    }

    func testSuccessClearsExistingPending() {
        var state = StartRetryState()
        state.record(sent: false)
        state.record(sent: true)
        XCTAssertFalse(state.pending)
    }
}
