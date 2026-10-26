import XCTest
@testable import AquaEchoCore

final class StopHandoffTests: XCTestCase {
    func testSlowFinishDoesNotBlockCaller() {
        let queue = DispatchQueue(label: "AquaEcho.StopHandoffTests")
        let done = expectation(description: "completion")
        var result = ""

        let started = Date()
        StopHandoff.run(
            queue: queue,
            snapshot: { "snapshot" },
            finish: { snap in
                Thread.sleep(forTimeInterval: 0.4)
                return snap + "-done"
            },
            completion: {
                result = $0
                done.fulfill()
            }
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.1, "stop 调用线程被 finish 阻塞")
        wait(for: [done], timeout: 2)
        XCTAssertEqual(result, "snapshot-done")
    }
}
