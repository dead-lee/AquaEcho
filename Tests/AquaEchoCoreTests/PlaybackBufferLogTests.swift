import XCTest
@testable import AquaEchoCore

final class PlaybackBufferLogTests: XCTestCase {
    func testRecordedSamplesMatchThePlaybackBufferAndTheGap() throws {
        let log = PlaybackBufferLog()
        let first: [Float] = [0.25, -0.5, 0.75, -1]
        let second: [Float] = [0.1, 0.2, 0.3]
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        log.append(first, startedAt: start)
        let gap = 0.001
        log.append(second, startedAt: start.addingTimeInterval(Double(first.count) / 48_000 + gap))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try XCTUnwrap(log.write(directory: folder, when: start))
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertEqual(url.lastPathComponent.hasPrefix(PlaybackBufferLog.filePrefix), true)
        let written = try FloatWav.readSamples(from: url)
        var expected = first
        expected.append(contentsOf: repeatElement(0, count: 48))
        expected.append(contentsOf: second)
        XCTAssertEqual(written, expected)
    }

    func testFileNameRejectsAnythingExceptTheWatchBuffer() {
        XCTAssertEqual(PlaybackBufferLog.acceptedFileName("AquaEcho_WatchTx_20261030_103000.wav"), "AquaEcho_WatchTx_20261030_103000.wav")
        XCTAssertNil(PlaybackBufferLog.acceptedFileName("../AquaEcho_WatchTx_20261030_103000.wav"))
        XCTAssertNil(PlaybackBufferLog.acceptedFileName("AquaEcho_Scan_air_20261030_103000.wav"))
    }
}
