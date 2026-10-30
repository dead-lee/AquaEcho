import XCTest
@testable import AquaEchoCore

/// 每个集合的前导落在自己的数据频段里，接收端只靠这段录音解出。
final class RecordingReplayTests: XCTestCase {
    func testEachSetDecodesFromItsOwnPreamble() {
        for set in SpectralSet.all {
            var config = ScanRunConfig()
            config.setIDs = [set.id]
            config.packetsPerSet = 2
            let receiver = ScanReceiver(config: config, startedAt: Date())
            var signal = [Float](repeating: 0, count: 4_000)
            for index in 0..<2 {
                let payload = ScanPayload.make(setID: set.id, packetIndex: index)
                signal.append(contentsOf: ScanProtocol.makeFrame(payload: payload, set: set))
                signal.append(contentsOf: [Float](repeating: 0, count: 2_000))
            }
            var cursor = 0
            while cursor < signal.count {
                let end = min(cursor + 2_048, signal.count)
                receiver.ingest(Array(signal[cursor..<end]), at: Date(), sampleRate: 48_000)
                cursor = end
            }
            XCTAssertEqual(receiver.finish().overallPassed, 2, set.id)
        }
    }

    /// 8 个集合同时开着。S0 和 S4 频段重叠，但仍按发送顺序各解各的包。
    func testSequentialOverlappingBandsDoNotStealEachOther() {
        var config = ScanRunConfig()
        config.setIDs = SpectralSet.all.map(\.id)
        config.packetsPerSet = 2
        let receiver = ScanReceiver(config: config, startedAt: Date())
        var signal = [Float](repeating: 0, count: 4_000)
        for id in ["S0", "S4"] {
            let set = try! XCTUnwrap(SpectralSet.set(id: id))
            for index in 0..<2 {
                let payload = ScanPayload.make(setID: set.id, packetIndex: index)
                signal.append(contentsOf: ScanProtocol.makeFrame(payload: payload, set: set))
                signal.append(contentsOf: [Float](repeating: 0, count: 4_000))
            }
        }
        // 解调要等最长集合的数据窗到齐，尾部补够静音。
        signal.append(contentsOf: [Float](repeating: 0, count: 20_000))
        var cursor = 0
        while cursor < signal.count {
            let end = min(cursor + 2_048, signal.count)
            receiver.ingest(Array(signal[cursor..<end]), at: Date(), sampleRate: 48_000)
            cursor = end
        }
        let analysis = receiver.finish()
        XCTAssertEqual(analysis.overallPassed, 4)
        XCTAssertEqual(analysis.summaries.first { $0.setID == "S0" }?.passed, 2)
        XCTAssertEqual(analysis.summaries.first { $0.setID == "S4" }?.passed, 2)
        XCTAssertEqual(analysis.corruptEvents, 0)
    }
}
