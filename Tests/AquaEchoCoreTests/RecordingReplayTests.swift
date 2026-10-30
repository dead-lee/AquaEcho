import XCTest
@testable import AquaEchoCore

/// 用手机落盘的 Float32 WAV 回放当前解调。调制解调改动先过这里，再装真机。
final class RecordingReplayTests: XCTestCase {
    func testFirstAirRecordingKeepsTheDecodableBands() throws {
        let analysis = try replay("AquaEcho_Scan_air_20261030_081656.wav")
        XCTAssertEqual(passed(analysis, "S0"), 20)
        XCTAssertEqual(passed(analysis, "S1"), 20)
        XCTAssertEqual(passed(analysis, "S3"), 0)
        XCTAssertGreaterThanOrEqual(analysis.overallPassed, 67)
    }

    func testSecondAirRecordingDemodulatesTheHandheldFrames() throws {
        let analysis = try replay("AquaEcho_Scan_air_20261030_081831.wav")
        XCTAssertEqual(passed(analysis, "S0"), 18)
        XCTAssertEqual(analysis.overallPassed, 18)
    }

    private func replay(_ name: String) throws -> ScanAnalysis {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var config = ScanRunConfig()
        config.packetsPerSet = 20
        let receiver = ScanReceiver(config: config, startedAt: Date())
        var cursor = 0
        while cursor < samples.count {
            let end = min(cursor + 2_048, samples.count)
            receiver.ingest(Array(samples[cursor..<end]), at: Date(), sampleRate: 48_000)
            cursor = end
        }
        return receiver.finish()
    }

    private func passed(_ analysis: ScanAnalysis, _ id: String) -> Int {
        analysis.summaries.first { $0.setID == id }?.passed ?? -1
    }
}
