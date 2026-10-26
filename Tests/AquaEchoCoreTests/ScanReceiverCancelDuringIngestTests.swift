import XCTest
@testable import AquaEchoCore

final class ScanReceiverCancelDuringIngestTests: XCTestCase {
    func testCancelReturnsQuicklyWhileIngestIsRunning() {
        let receiver = ScanReceiver(config: ScanRunConfig(), startedAt: Date())
        let queue = DispatchQueue(label: "AquaEcho.CancelDuringIngest")
        let started = expectation(description: "ingest started")

        queue.async {
            started.fulfill()
            receiver.ingest([Float](repeating: 0, count: 2_000_000), at: Date(), sampleRate: 48000)
        }
        wait(for: [started], timeout: 1)

        let begin = Date()
        receiver.cancel()
        let elapsed = Date().timeIntervalSince(begin)
        _ = receiver.finish()
        XCTAssertLessThan(elapsed, 0.1, "cancel 被接收锁阻塞")
    }
}
