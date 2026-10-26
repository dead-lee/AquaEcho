import XCTest
@testable import AquaEchoCore

final class WorkoutStartPolicyTests: XCTestCase {
    func testBackgroundNeverStarts() {
        XCTAssertFalse(WorkoutStartPolicy.shouldStart(isBackground: true, running: false, starting: false))
    }

    func testActiveStartsOnlyWhenIdle() {
        XCTAssertTrue(WorkoutStartPolicy.shouldStart(isBackground: false, running: false, starting: false))
        XCTAssertFalse(WorkoutStartPolicy.shouldStart(isBackground: false, running: true, starting: false))
        XCTAssertFalse(WorkoutStartPolicy.shouldStart(isBackground: false, running: false, starting: true))
    }
}
