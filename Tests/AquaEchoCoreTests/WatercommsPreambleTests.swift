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

    func testW0KeepsTheOriginalNaiserAndOtherBandsDiffer() {
        let w0 = try! XCTUnwrap(SpectralSet.set(id: "W0"))
        XCTAssertEqual(WatercommsPhy.preamble(for: w0), WatercommsPreamble.samples)
        let s3 = try! XCTUnwrap(SpectralSet.set(id: "S3"))
        let other = WatercommsPhy.preamble(for: s3)
        XCTAssertEqual(other.count, 9_360)
        let scores = WatercommsPhy.preambleScores(in: other, kernel: WatercommsPreamble.samples)
        let peak = scores.max() ?? 1
        XCTAssertLessThan(peak, 0.2, "4–8 kHz 前导不应再撞上 1–4 kHz 模板，峰=\(peak)")
    }
}
