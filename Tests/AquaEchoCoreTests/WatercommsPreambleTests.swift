import XCTest
@testable import AquaEchoCore

final class WatercommsPreambleTests: XCTestCase {
    func testFindPreambleWithLeadingOffset() {
        let set = SpectralSet.all[0]
        let payload = ScanPayload.make(setCode: set.code, packetIndex: 7)
        let frame = WatercommsPhy.makeFrame(payload: payload, set: set)
        let offset = 1234
        let signal = [Float](repeating: 0, count: offset) + frame
        let starts = WatercommsPhy.findPreambleStarts(in: signal)
        XCTAssertTrue(starts.contains(offset), "candidates \(starts.prefix(5))")
        XCTAssertEqual(WatercommsPhy.decode(samples: signal, start: starts.first!, set: set), payload)
    }
}
