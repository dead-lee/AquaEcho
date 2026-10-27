import XCTest
@testable import AquaEchoCore

final class ControlDeliveryPolicyTests: XCTestCase {
    func testUnreachableCommandsMustQueue() {
        XCTAssertTrue(ControlDeliveryPolicy.shouldQueue(isReachable: false))
        XCTAssertFalse(ControlDeliveryPolicy.shouldQueue(isReachable: true))
    }
}
