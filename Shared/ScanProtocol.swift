import Foundation

/// 单向扫描协议：
///   标记音（30 ms，集合专属频率） + 保护间隔（10 ms） +
///   OFDM 训练符号 + S 个数据符号（每符号 20 ms + 5 ms 循环前缀） + 结尾静音（20 ms）
///
/// 标记音同时承担同步和集合识别；数据帧里没有前导、没有握手、没有 CRC。
enum ScanProtocol {
    static let sampleRate: Double = 48_000
    static let symbolLength = 960
    static let cyclicPrefix = 240
    static let symbolSamples = symbolLength + cyclicPrefix

    static let markerMs: Double = 30
    static let markerHz: Double = 400
    static let guardMs: Double = 10
    static let tailMs: Double = 20

    static let markerSamples = Int(markerMs / 1_000 * sampleRate)
    static let guardSamples = Int(guardMs / 1_000 * sampleRate)
    static let tailSamples = Int(tailMs / 1_000 * sampleRate)

    /// 数据符号（含训练符号）之前的总偏移：标记音 + 保护间隔。
    static let dataStartOffset = markerSamples + guardSamples

    static func dataSymbols(for set: SpectralSet) -> Int { set.dataSymbols }

    static func dataSamples(for set: SpectralSet) -> Int {
        (1 + dataSymbols(for: set)) * symbolSamples
    }

    static func frameSamples(for set: SpectralSet) -> Int {
        markerSamples + guardSamples + dataSamples(for: set) + tailSamples
    }

    static func expectedSeconds(for config: ScanRunConfig) -> Double {
        let normalized = config.normalized
        let sets = normalized.activeSets
        let count = Double(sets.reduce(0) { $0 + frameSamples(for: $1) })
        let seconds = count * Double(normalized.packetsPerSet) / sampleRate
        return seconds * 1.10 + 1.5
    }

    static func plan(for set: SpectralSet) -> OFDMModem.Plan {
        OFDMModem.plan(
            carriers: set.carriers,
            sampleRate: sampleRate,
            ns: symbolLength,
            cp: cyclicPrefix,
            preamble: [],
            gap: 0,
            bitCount: ConvolutionalCode.encodedBitCount
        )
    }

    static func makeFrame(payload: UInt64, set: SpectralSet) -> [Float] {
        let marker = tone(frequency: ScanProtocol.markerHz, durationMs: markerMs, amplitude: 0.85)
        let guardGap = [Float](repeating: 0, count: Self.guardSamples)
        let bits = PacketLayout.bits(for: PacketLayout.data(from: payload))
        let coded = ConvolutionalCode.encode(bits)
        let plan = plan(for: set)
        let data = OFDMModem.render(bits: coded, plan: plan)
        let tailGap = [Float](repeating: 0, count: Self.tailSamples)

        var frame: [Float] = []
        frame.reserveCapacity(frameSamples(for: set))
        frame.append(contentsOf: marker)
        frame.append(contentsOf: guardGap)
        frame.append(contentsOf: data)
        frame.append(contentsOf: tailGap)
        return frame
    }

    static func tone(frequency: Double, durationMs: Double, amplitude: Float) -> [Float] {
        let count = max(1, Int((durationMs / 1_000 * sampleRate).rounded()))
        var output = [Float](repeating: 0, count: count)
        let fade = min(count / 2, max(1, Int(0.003 * sampleRate)))
        for index in 0..<count {
            var envelope = 1.0
            if index < fade {
                envelope = Double(index) / Double(fade)
            } else if index >= count - fade {
                envelope = Double(count - 1 - index) / Double(fade)
            }
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            output[index] = Float(sin(phase) * envelope) * amplitude
        }
        return output
    }

    /// 可选：宽频声测用 chirp。当前扫描不逐包发送，保留给后续“声道测量”模式。
    static func linearChirp(lowHz: Double, highHz: Double, durationMs: Double) -> [Float] {
        let count = max(1, Int((durationMs / 1_000 * sampleRate).rounded()))
        let duration = Double(count) / sampleRate
        var output = [Float](repeating: 0, count: count)
        let fade = min(count / 2, max(1, Int(0.003 * sampleRate)))
        for index in 0..<count {
            let time = Double(index) / sampleRate
            let phase = 2 * Double.pi * (lowHz * time + (highHz - lowHz) / (2 * duration) * time * time)
            var envelope = 1.0
            if index < fade {
                envelope = Double(index) / Double(fade)
            } else if index >= count - fade {
                envelope = Double(count - 1 - index) / Double(fade)
            }
            output[index] = Float(sin(phase) * envelope) * 0.9
        }
        return output
    }
}
