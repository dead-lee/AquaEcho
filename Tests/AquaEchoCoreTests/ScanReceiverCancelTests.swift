import XCTest
@testable import AquaEchoCore

final class ScanReceiverCancelTests: XCTestCase {
    func testCancelDropsQueuedBacklogAndFinishesFast() {
        let config = ScanRunConfig()
        let receiver = ScanReceiver(config: config, startedAt: Date())
        receiver.cancel()

        let started = Date()
        receiver.ingest([Float](repeating: 0, count: 48000 * 20), at: Date(), sampleRate: 48000)
        let analysis = receiver.finish()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.5, "停止后仍在处理积压音频")
        XCTAssertEqual(analysis.overallPassed, 0)
    }
}
