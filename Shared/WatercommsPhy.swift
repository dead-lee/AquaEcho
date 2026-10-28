import Foundation
import Accelerate

/// watercomms 对齐版 PHY：Naiser3 前导 + 960 gap + 训练/数据符号，Ns=960、Cp=67。
enum WatercommsPhy {
    static let ns = 960
    static let cp = 67
    static let gap = 960
    static var preamble: [Float] { WatercommsPreamble.samples }

    static func plan(for set: SpectralSet) -> OFDMModem.Plan {
        OFDMModem.plan(
            carriers: set.carriers,
            sampleRate: ScanProtocol.sampleRate,
            ns: ns,
            cp: cp,
            preamble: preamble,
            gap: gap,
            bitCount: ConvolutionalCode.encodedBitCount
        )
    }

    static func makeFrame(payload: UInt64, set: SpectralSet) -> [Float] {
        let bits = PacketLayout.bits(for: PacketLayout.data(from: payload))
        let coded = ConvolutionalCode.encode(bits)
        return OFDMModem.render(bits: coded, plan: plan(for: set))
    }

    /// 直接归一化互相关（离线/测试用）；前导起始 = lag。
    static func findPreambleStarts(in samples: [Float], limit: Int = 8) -> [Int] {
        let p = preamble
        guard samples.count >= p.count, !p.isEmpty else { return [] }
        let pEnergy = p.reduce(0) { $0 + Double($1 * $1) }
        guard pEnergy > 0 else { return [] }
        var candidates: [(Int, Float)] = []
        let maxLag = samples.count - p.count
        guard maxLag >= 0 else { return [] }
        for lag in 0...maxLag {
            var dot: Float = 0
            var energy: Float = 0
            for j in 0..<p.count {
                let v = samples[lag + j]
                dot += v * p[j]
                energy += v * v
            }
            guard energy > 0 else { continue }
            let score = dot / sqrt(energy * Float(pEnergy))
            if score > 0.15 {
                candidates.append((lag, score))
            }
        }
        return candidates.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    static func findPreambleStart(in samples: [Float]) -> Int? {
        findPreambleStarts(in: samples, limit: 1).first
    }

    static func decode(frame: [Float], set: SpectralSet) -> UInt64? {
        decode(samples: frame, start: 0, set: set)
    }

    static func decode(samples: [Float], start: Int, set: SpectralSet) -> UInt64? {
        let dataStart = start + preamble.count + gap
        guard dataStart >= 0, dataStart < samples.count else { return nil }
        let plan = plan(for: set)
        guard let demod = OFDMModem.demodulateFrequencyOnly(window: samples, symbolStart: dataStart, plan: plan) else { return nil }
        let decoded = ConvolutionalCode.decode(demod.bits)
        guard decoded.count == PacketLayout.bitCount else { return nil }
        var word: UInt64 = 0
        for bit in decoded { word = (word << 1) | (bit ? 1 : 0) }
        guard ScanPayload.setCode(of: word) == set.code else { return nil }
        return word
    }
}
