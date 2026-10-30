import XCTest
@testable import AquaEchoCore

final class ChannelLookbackTests: XCTestCase {
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

    func testLateCorrelationPeakIsPulledBackToTheFrame() {
        let set = try! XCTUnwrap(SpectralSet.set(id: "S2"))
        let payload = ScanPayload.make(setID: set.id, packetIndex: 4)
        let frame = WatercommsPhy.makeFrame(payload: payload, set: set)
        let trueStart = 2_000
        var samples = [Float](repeating: 0, count: trueStart + frame.count + 2_000)
        samples.replaceSubrange(trueStart..<(trueStart + frame.count), with: frame)

        let late = trueStart + 112
        let template = WatercommsPhy.preamble(for: set)
        let start = WatercommsPhy.channelLookbackStart(
            samples: samples, seekbackLag: late, preamble: template, lowHz: set.lowHz, highHz: set.highHz
        )
        XCTAssertLessThan(abs(start - trueStart), abs(late - trueStart), "lookback=\(start) late=\(late) true=\(trueStart)")
        XCTAssertEqual(WatercommsPhy.decode(samples: samples, start: start, set: set), payload)

        let aligned = WatercommsPhy.channelLookbackStart(
            samples: samples, seekbackLag: trueStart, preamble: template, lowHz: set.lowHz, highHz: set.highHz
        )
        XCTAssertLessThanOrEqual(abs(aligned - trueStart), WatercommsPhy.cp, "aligned=\(aligned)")
    }

    func testReceivedSoundDecodesWithoutWatchState() {
        let set = try! XCTUnwrap(SpectralSet.set(id: "S1"))
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
        config.setIDs = ["S0"]
        config.packetsPerSet = 1
        let receiver = ScanReceiver(config: config, startedAt: Date())
        receiver.ingest([Float](repeating: 0, count: 80_000), at: Date(), sampleRate: 48_000)
        XCTAssertEqual(receiver.finish().overallPassed, 0)
    }
}
