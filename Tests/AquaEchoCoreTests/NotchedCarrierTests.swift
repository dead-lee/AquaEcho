import XCTest
@testable import AquaEchoCore

/// 袋子和手的位置会让几路载波整段陷落。软判决让这些载波的乱比特几乎不计分。
final class NotchedCarrierTests: XCTestCase {
    func testSoftViterbiSurvivesNotchedCarriers() {
        let set = try! XCTUnwrap(SpectralSet.set(id: "C8"))
        let payload = ScanPayload.make(setID: set.id, packetIndex: 7)
        let plan = WatercommsPhy.plan(for: set)
        var samples = WatercommsPhy.makeFrame(payload: payload, set: set) + [Float](repeating: 0, count: 2_000)
        let dataStart = plan.preamble.count + plan.gap
        let notched = plan.carriers.filter { (34...35).contains($0) }
        XCTAssertEqual(notched.count, 2)

        for symbol in 0...plan.dataCounts.count {
            let body = dataStart + symbol * plan.symbolSamples + plan.cp
            for bin in notched {
                attenuate(&samples, bodyStart: body, length: plan.ns, bin: bin, keep: 0.01)
            }
        }
        var random = SeededRandom(seed: 20261106)
        for index in samples.indices {
            samples[index] += 0.05 * random.nextGaussian()
        }

        let demod = try! XCTUnwrap(OFDMModem.demodulateFrequencyOnly(window: samples, symbolStart: dataStart, plan: plan))
        let soft = ConvolutionalCode.decode(demod.soft)
        let hard = ConvolutionalCode.decode(demod.soft.map { $0 > 0 ? 1 : -1 })
        XCTAssertEqual(word(soft), payload)
        XCTAssertNotEqual(word(hard), payload)
    }

    /// 符号体里整数格的载波互相正交，减去该格的投影就是只衰减这一路。
    private func attenuate(_ samples: inout [Float], bodyStart: Int, length: Int, bin: Int, keep: Double) {
        let omega = 2 * Double.pi * Double(bin) / Double(length)
        var re = 0.0
        var im = 0.0
        for n in 0..<length {
            let value = Double(samples[bodyStart + n])
            re += value * cos(omega * Double(n))
            im -= value * sin(omega * Double(n))
        }
        let scale = 2 / Double(length) * (1 - keep)
        for n in 0..<length {
            let component = scale * (re * cos(omega * Double(n)) - im * sin(omega * Double(n)))
            samples[bodyStart + n] -= Float(component)
        }
    }

    private func word(_ bits: [Bool]) -> UInt64 {
        bits.reduce(0) { ($0 << 1) | ($1 ? 1 : 0) }
    }
}

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func nextUniform() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return (Double(state >> 11) + 0.5) / Double(1 << 53)
    }

    mutating func nextGaussian() -> Float {
        Float(sqrt(-2 * log(nextUniform())) * cos(2 * Double.pi * nextUniform()))
    }
}
