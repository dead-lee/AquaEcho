import XCTest
@testable import AquaEchoCore

final class WatercommsLoopbackTests: XCTestCase {
    func testEverySetLoopbackDecodes() {
        for set in SpectralSet.all {
            let payload = ScanPayload.make(setCode: set.code, packetIndex: 3)
            let frame = WatercommsPhy.makeFrame(payload: payload, set: set)
            XCTAssertEqual(WatercommsPhy.decode(frame: frame, set: set), payload, set.id)
        }
    }
}
