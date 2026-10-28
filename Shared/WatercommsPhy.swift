import Foundation

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

    static func decode(frame: [Float], set: SpectralSet) -> UInt64? {
        guard frame.count > preamble.count + gap else { return nil }
        let dataStart = preamble.count + gap
        let plan = plan(for: set)
        guard let demod = OFDMModem.demodulateFrequencyOnly(window: frame, symbolStart: dataStart, plan: plan) else { return nil }
        let decoded = ConvolutionalCode.decode(demod.bits)
        guard decoded.count == PacketLayout.bitCount else { return nil }
        var word: UInt64 = 0
        for bit in decoded { word = (word << 1) | (bit ? 1 : 0) }
        guard ScanPayload.setCode(of: word) == set.code else { return nil }
        return word
    }
}
