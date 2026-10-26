import XCTest
@testable import AquaEchoCore

final class LogUIBatcherTests: XCTestCase {
    func testManyLinesProduceOneSnapshotAndKeepTail() {
        let batcher = LogUIBatcher(maxChars: 500, autoFlush: false)
        var flushes: [String] = []
        batcher.onFlush = { flushes.append($0) }

        for i in 0..<1000 {
            batcher.append("line \(i)\n")
        }
        batcher.flushNow()

        XCTAssertEqual(flushes.count, 1)
        XCTAssertTrue(flushes[0].contains("line 999"))
        XCTAssertLessThanOrEqual(flushes[0].count, 500)
    }

    func testEmptyFlushDoesNotPublish() {
        let batcher = LogUIBatcher(autoFlush: false)
        var count = 0
        batcher.onFlush = { _ in count += 1 }
        batcher.flushNow()
        XCTAssertEqual(count, 0)
    }
}
