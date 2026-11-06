import XCTest
@testable import AquaEchoCore

final class WatercommsLoopbackTests: XCTestCase {
    func testWatercommsBaselineLayout() {
        let set = try! XCTUnwrap(SpectralSet.set(id: "C8"))
        XCTAssertEqual(set.carriers, Array(32...39))
        let plan = WatercommsPhy.plan(for: set)
        XCTAssertEqual(plan.ns, 960)
        XCTAssertEqual(plan.cp, 67)
        XCTAssertEqual(plan.gap, 960)
        XCTAssertEqual(plan.preamble.count, 9_360)
        XCTAssertEqual(plan.dataCounts, Array(repeating: 8, count: 13) + Array(repeating: 7, count: 6))
        let pn60 = Array("100000100001100010100111101000111001001011011101100110101011").map { $0 == "1" }
        XCTAssertEqual(plan.trainingBits, Array(pn60.prefix(set.carrierCount)))

        let payload = ScanPayload.make(setID: set.id, packetIndex: 0)
        let frame = WatercommsPhy.makeFrame(payload: payload, set: set)
        let symbolStart = plan.preamble.count + plan.gap
        let body = Array(frame[(symbolStart + plan.cp)..<(symbolStart + plan.cp + plan.ns)])
        let prefix = Array(frame[symbolStart..<(symbolStart + plan.cp)])
        let copied = Array(body[(plan.ns - plan.cp - 1)..<(plan.ns - 1)])
        XCTAssertEqual(prefix, copied)
        XCTAssertEqual(ScanProtocol.makeFrame(payload: payload, set: set), frame)
    }

    func testOldConfigResetsToC8AndC4() throws {
        let json = #"{"scenario":"air","distanceCm":30,"notes":"desk","packetsPerSet":20,"setIDs":["C8","A40"],"catalogVersion":7}"#
        let decoded = try JSONDecoder().decode(ScanRunConfig.self, from: Data(json.utf8))
        let config = decoded.normalized
        XCTAssertEqual(config.activeSets.map(\.id), ["C8", "C4"])
        XCTAssertEqual(ScanRunConfig().normalized.activeSets.map(\.id), ["C8", "C4"])
        XCTAssertEqual(config.distanceCm, 30)
        XCTAssertEqual(config.notes, "desk")
        XCTAssertEqual(config.packetsPerSet, 20)
    }

    func testEverySetLoopbackDecodes() {
        for set in SpectralSet.all {
            let payload = ScanPayload.make(setCode: set.code, packetIndex: 3)
            let frame = WatercommsPhy.makeFrame(payload: payload, set: set)
            XCTAssertEqual(WatercommsPhy.decode(frame: frame, set: set), payload, set.id)
        }
    }

    func testLiveCatalogStaysInsideTheUsableBand() {
        for set in SpectralSet.all {
            XCTAssertGreaterThanOrEqual(set.lowHz, 500, set.id)
            XCTAssertLessThanOrEqual(set.highHz, 2_500, set.id)
            XCTAssertTrue(set.carriers.allSatisfy { (10...49).contains($0) }, "\(set.id) \(set.carriers)")
        }
        XCTAssertEqual(SpectralSet.all.map(\.id), ["C8", "C4"])
        XCTAssertEqual(SpectralSet.set(id: "C8")?.carrierCount, 8)
        XCTAssertEqual(SpectralSet.set(id: "C4")?.carrierCount, 4)
        XCTAssertEqual(SpectralSet.set(id: "C8")?.code, 2)
        XCTAssertEqual(SpectralSet.set(id: "C4")?.code, 8)
    }

    /// C4 只用 C8 上半段的 4 路载波，前导和同步频段与 C8 相同。
    func testNarrowC4KeepsTheC8Preamble() {
        let c8 = try! XCTUnwrap(SpectralSet.set(id: "C8"))
        let c4 = try! XCTUnwrap(SpectralSet.set(id: "C4"))
        XCTAssertEqual(c4.carriers, Array(36...39))
        XCTAssertEqual(WatercommsPhy.preamble(for: c4), WatercommsPhy.preamble(for: c8))
        XCTAssertTrue(WatercommsPhy.syncBand(for: c4) == WatercommsPhy.syncBand(for: c8))

        let plan = WatercommsPhy.plan(for: c4)
        XCTAssertEqual(plan.dataCounts.count, 37)
        let frame = WatercommsPhy.makeFrame(payload: ScanPayload.make(setID: c4.id, packetIndex: 0), set: c4)
        let body = Array(frame[(plan.preamble.count + plan.gap + plan.cp)..<(plan.preamble.count + plan.gap + plan.cp + plan.ns)])
        let power = { (bin: Int) -> Double in
            let omega = 2 * Double.pi * Double(bin) / Double(plan.ns)
            var re = 0.0
            var im = 0.0
            for (n, value) in body.enumerated() {
                re += Double(value) * cos(omega * Double(n))
                im -= Double(value) * sin(omega * Double(n))
            }
            return re * re + im * im
        }
        for bin in 32...35 {
            XCTAssertLessThan(power(bin), power(36) * 1e-6, "bin \(bin)")
        }
    }
}
