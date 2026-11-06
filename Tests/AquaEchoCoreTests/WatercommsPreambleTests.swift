import XCTest
@testable import AquaEchoCore

final class WatercommsPreambleTests: XCTestCase {
    func testNormalizedCorrelationIsUnityAtTrueLag() {
        let offset = 100
        let signal = [Float](repeating: 0, count: offset) + WatercommsPhy.preamble
        let scores = WatercommsPhy.preambleScores(in: signal)
        let peak = scores.enumerated().max { $0.element < $1.element }
        XCTAssertEqual(WatercommsPhy.preamble.count, 9_360)
        XCTAssertEqual(peak?.offset, offset)
        XCTAssertEqual(peak?.element ?? 0, 1, accuracy: Float(0.02))
    }

    func testFindPreambleWithLeadingOffset() {
        let set = SpectralSet.all[0]
        let payload = ScanPayload.make(setCode: set.code, packetIndex: 7)
        let frame = WatercommsPhy.makeFrame(payload: payload, set: set)
        let offset = 1234
        let signal = [Float](repeating: 0, count: offset) + frame
        let starts = WatercommsPhy.findPreambleStarts(in: signal, set: set)
        XCTAssertTrue(starts.contains(offset), "candidates \(starts.prefix(5))")
        XCTAssertEqual(WatercommsPhy.decode(samples: signal, start: starts.first!, set: set), payload)
    }

    func testSeparatedBandsDoNotShareAPreamble() {
        let low = try! XCTUnwrap(SpectralSet.set(id: "A8"))
        let high = try! XCTUnwrap(SpectralSet.set(id: "C8"))
        let other = WatercommsPhy.preamble(for: high)
        XCTAssertEqual(other.count, 9_360)
        let scores = WatercommsPhy.preambleScores(in: other, kernel: WatercommsPhy.preamble(for: low))
        let peak = scores.max() ?? 1
        XCTAssertLessThan(peak, 0.2, "0.5–0.9 kHz 与 1.6–2.0 kHz 前导不应撞上，峰=\(peak)")
    }
}
