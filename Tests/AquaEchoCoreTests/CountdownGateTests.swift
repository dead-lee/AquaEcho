import XCTest
@testable import AquaEchoCore

/// 手表倒计时里入水会出假峰。门限前的峰不算包，也不推进约定顺序。
final class CountdownGateTests: XCTestCase {
    func testPeaksBeforeTheCountdownGateAreNotPackets() {
        let (signal, gateSamples) = makeSignal()

        let open = run(signal, gateSeconds: nil)
        XCTAssertEqual(open.corruptEvents, 1)

        let gated = run(signal, gateSeconds: Double(gateSamples) / 48_000)
        XCTAssertEqual(gated.corruptEvents, 0)
        XCTAssertEqual(gated.overallPassed, 4)
        XCTAssertEqual(gated.summaries.first { $0.setID == "C8" }?.passed, 2)
        XCTAssertEqual(gated.summaries.first { $0.setID == "C4" }?.passed, 2)
    }

    private func makeSignal() -> ([Float], Int) {
        let c8 = try! XCTUnwrap(SpectralSet.set(id: "C8"))
        var signal = [Float](repeating: 0, count: 4_000)
        // 前导真、数据乱：能过相关门限，解不出。
        var random = SystemRandomNumberGenerator()
        signal.append(contentsOf: WatercommsPhy.preamble(for: c8))
        signal.append(contentsOf: [Float](repeating: 0, count: WatercommsPhy.gap))
        let dataCount = ScanProtocol.frameSamples(for: c8) - ScanProtocol.dataStartOffset
        signal.append(contentsOf: (0..<dataCount).map { _ in Float.random(in: -0.5...0.5, using: &random) })
        signal.append(contentsOf: [Float](repeating: 0, count: 2_000))
        let gate = signal.count
        for id in ["C8", "C4"] {
            let set = try! XCTUnwrap(SpectralSet.set(id: id))
            for index in 0..<2 {
                signal.append(contentsOf: ScanProtocol.makeFrame(payload: ScanPayload.make(setID: id, packetIndex: index), set: set))
                signal.append(contentsOf: [Float](repeating: 0, count: 4_000))
            }
        }
        signal.append(contentsOf: [Float](repeating: 0, count: 20_000))
        return (signal, gate)
    }

    private func run(_ signal: [Float], gateSeconds: Double?) -> ScanAnalysis {
        var config = ScanRunConfig()
        config.setIDs = ["C8", "C4"]
        config.packetsPerSet = 2
        let receiver = ScanReceiver(config: config, startedAt: Date())
        if let gateSeconds {
            receiver.ignorePreambles(forSeconds: gateSeconds)
        }
        var cursor = 0
        while cursor < signal.count {
            let end = min(cursor + 2_048, signal.count)
            receiver.ingest(Array(signal[cursor..<end]), at: Date(), sampleRate: 48_000)
            cursor = end
        }
        return receiver.finish()
    }
}
