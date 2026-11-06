import XCTest
@testable import AquaEchoCore

final class WatercommsLoopbackTests: XCTestCase {
    func testWatercommsBaselineLayout() {
        let set = try! XCTUnwrap(SpectralSet.set(id: "S0"))
        XCTAssertEqual(set.carriers, Array(10...29))
        let plan = WatercommsPhy.plan(for: set)
        XCTAssertEqual(plan.ns, 960)
        XCTAssertEqual(plan.cp, 67)
        XCTAssertEqual(plan.gap, 960)
        XCTAssertEqual(plan.preamble.count, 9_360)
        XCTAssertEqual(plan.dataCounts, [19, 19, 18, 18, 18, 18, 18, 18])
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

    func testOldConfigResetsToE16AndS1() throws {
        let json = #"{"scenario":"air","distanceCm":30,"notes":"desk","packetsPerSet":20,"setIDs":["S0","S1"]}"#
        let decoded = try JSONDecoder().decode(ScanRunConfig.self, from: Data(json.utf8))
        let config = decoded.normalized
        XCTAssertEqual(config.activeSets.map(\.id), ["E16", "S1"])
        XCTAssertEqual(ScanRunConfig().normalized.activeSets.map(\.id), ["E16", "S1"])
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
        XCTAssertEqual(SpectralSet.set(id: "A8")?.carrierCount, 8)
        XCTAssertEqual(SpectralSet.set(id: "D16")?.carrierCount, 16)
        XCTAssertEqual(SpectralSet.set(id: "A40")?.carrierCount, 40)
    }
}
