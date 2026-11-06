import XCTest
@testable import AquaEchoCore

final class FrameStartTests: XCTestCase {
    func testSyncBandpassKeepsThePreambleLag() {
        let preamble = WatercommsPreamble.samples
        let start = 2_000
        var samples = [Float](repeating: 0, count: start + preamble.count + 2_000)
        samples.replaceSubrange(start..<(start + preamble.count), with: preamble)
        let filtered = WatercommsPhy.bandpassForSync(samples)
        let scores = WatercommsPhy.preambleScores(in: filtered)
        let peak = scores.enumerated().max { $0.element < $1.element }
        let lag = (peak?.offset ?? -1) + WatercommsPhy.syncFilterDelay
        XCTAssertEqual(lag, start, "peak=\(peak?.offset ?? -1) score=\(peak?.element ?? -1)")
        XCTAssertGreaterThan(peak?.element ?? 0, 0.8)
    }

    /// 400 Hz 宽的 C8 上，watercomms 的最早径会落到主瓣前的旁瓣，早 168 点。seekback 约早 80 点，仍能解出。
    func testNarrowBandFrameStartUsesSeekback() {
        let set = try! XCTUnwrap(SpectralSet.set(id: "C8"))
        var config = ScanRunConfig()
        config.setIDs = [set.id]
        config.packetsPerSet = 1
        let payload = ScanPayload.make(setID: set.id, packetIndex: 0)
        let trueStart = 3_000
        var generator = SystemRandomNumberGenerator()
        var signal = (0..<(trueStart + ScanProtocol.frameSamples(for: set) + 3_000)).map { _ in
            Float.random(in: -0.003...0.003, using: &generator)
        }
        for (index, value) in ScanProtocol.makeFrame(payload: payload, set: set).enumerated() {
            signal[trueStart + index] += value
        }

        let receiver = ScanReceiver(config: config, startedAt: Date())
        receiver.ingest(signal, at: Date(), sampleRate: 48_000)
        let analysis = receiver.finish()

        XCTAssertEqual(analysis.overallPassed, 1)
        let frameSample = try! XCTUnwrap(analysis.packets.first { $0.passed }?.frameSample)
        XCTAssertLessThanOrEqual(abs(frameSample - trueStart), 100, "frameSample=\(frameSample)")
    }

    func testReceivedSoundDecodesWithoutWatchState() {
        let set = try! XCTUnwrap(SpectralSet.set(id: "A40"))
        var config = ScanRunConfig()
        config.setIDs = [set.id]
        config.packetsPerSet = 1
        let payload = ScanPayload.make(setID: set.id, packetIndex: 0)
        let frame = ScanProtocol.makeFrame(payload: payload, set: set)
        let signal = [Float](repeating: 0, count: 3_000) + frame + [Float](repeating: 0, count: 2_000)

        let receiver = ScanReceiver(config: config, startedAt: Date())
        receiver.ingest(signal, at: Date(), sampleRate: 48_000)
        let analysis = receiver.finish()

        XCTAssertEqual(analysis.overallPassed, 1)
        XCTAssertEqual(analysis.packets.first?.decodedHex, ScanPayload.hex(payload))
        XCTAssertEqual(
            WatchRuntimePolicy.playbackEffect(willResignActive: true, didEnterBackground: false),
            .keepPlaying
        )
        XCTAssertEqual(
            WatchRuntimePolicy.playbackEffect(willResignActive: false, didEnterBackground: true),
            .stopAndEndWorkout
        )
    }

    func testSilenceProducesNoPacket() {
        var config = ScanRunConfig()
        config.setIDs = ["C8"]
        config.packetsPerSet = 1
        let receiver = ScanReceiver(config: config, startedAt: Date())
        receiver.ingest([Float](repeating: 0, count: 80_000), at: Date(), sampleRate: 48_000)
        XCTAssertEqual(receiver.finish().overallPassed, 0)
    }
}
