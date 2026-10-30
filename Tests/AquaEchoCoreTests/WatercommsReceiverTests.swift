import XCTest
@testable import AquaEchoCore

final class WatercommsReceiverTests: XCTestCase {
    func testChunkedCaptureDecodesWatercommsFrame() {
        let set = try! XCTUnwrap(SpectralSet.set(id: "W0"))
        var config = ScanRunConfig()
        config.setIDs = [set.id]
        config.packetsPerSet = 1
        let payload = ScanPayload.make(setID: set.id, packetIndex: 0)
        let frame = ScanProtocol.makeFrame(payload: payload, set: set)
        let signal = [Float](repeating: 0, count: 2_500) + frame + [Float](repeating: 0, count: 4_000)

        let receiver = ScanReceiver(config: config, startedAt: Date())
        var lines: [String] = []
        receiver.onLog = { lines.append($0) }

        var cursor = 0
        while cursor < signal.count {
            let end = min(cursor + 2_048, signal.count)
            receiver.ingest(Array(signal[cursor..<end]), at: Date(), sampleRate: 48_000)
            cursor = end
        }
        let analysis = receiver.finish()
        let log = lines.joined(separator: "\n")
        XCTAssertEqual(analysis.overallPassed, 1, log)
        XCTAssertEqual(analysis.corruptEvents, 0, log)
        XCTAssertEqual(analysis.packets.first?.decodedHex, ScanPayload.hex(payload), log)
    }
}
