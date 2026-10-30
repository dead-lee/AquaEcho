import XCTest
@testable import AquaEchoCore

final class ChannelLookbackTests: XCTestCase {
    func testLateCorrelationPeakIsPulledBackToTheFrame() {
        let set = try! XCTUnwrap(SpectralSet.set(id: "S2"))
        let payload = ScanPayload.make(setID: set.id, packetIndex: 4)
        let frame = WatercommsPhy.makeFrame(payload: payload, set: set)
        let trueStart = 2_000
        var samples = [Float](repeating: 0, count: trueStart + frame.count + 2_000)
        samples.replaceSubrange(trueStart..<(trueStart + frame.count), with: frame)

        let late = trueStart + 112
        let start = WatercommsPhy.channelLookbackStart(samples: samples, seekbackLag: late)
        XCTAssertLessThan(abs(start - trueStart), abs(late - trueStart), "lookback=\(start) late=\(late) true=\(trueStart)")
        XCTAssertEqual(WatercommsPhy.decode(samples: samples, start: start, set: set), payload)

        let aligned = WatercommsPhy.channelLookbackStart(samples: samples, seekbackLag: trueStart)
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
