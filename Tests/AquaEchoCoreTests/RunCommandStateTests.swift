import XCTest
@testable import AquaEchoCore

final class RunCommandStateTests: XCTestCase {
    func testStartStartStopStartIsSequential() {
        var state = RunCommandState()
        XCTAssertEqual(state.applyStart(), 1)
        XCTAssertEqual(state.applyStart(), 2)
        state.applyStop()
        XCTAssertFalse(state.running)
        XCTAssertEqual(state.applyStart(), 3)
        XCTAssertTrue(state.running)
    }

    func testDuplicateStopIsConsumedWithoutError() {
        var state = RunCommandState()
        state.applyStart()
        state.applyStop()
        state.applyStop()
        XCTAssertFalse(state.running)
    }
}
