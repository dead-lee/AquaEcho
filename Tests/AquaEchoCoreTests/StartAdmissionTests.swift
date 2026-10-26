import XCTest
@testable import AquaEchoCore

final class StartAdmissionTests: XCTestCase {
    func testSecondBeginRejectedUntilEnd() {
        var gate = StartAdmission()
        XCTAssertTrue(gate.tryBegin())
        XCTAssertFalse(gate.tryBegin())
        gate.end()
        XCTAssertTrue(gate.tryBegin())
    }
}
