import Foundation

/// 单向扫描协议，调制解调与 watercomms 对齐：
///   本频段 Naiser 前导（9360） + ChirpGap（960） + OFDM 训练符号 + 数据符号（Ns=960，Cp=67）
///
/// 集合改变子载波频段，前导下扫落在同一频段。帧里没有 400 Hz 标记音，没有握手，没有 CRC。
enum ScanProtocol {
    static let sampleRate: Double = 48_000
    static let symbolLength = WatercommsPhy.ns
    static let cyclicPrefix = WatercommsPhy.cp
    static let symbolSamples = symbolLength + cyclicPrefix
    static let chirpGap = WatercommsPhy.gap

    static var preambleSamples: Int { WatercommsPhy.preamble.count }

    /// 训练符号（含循环前缀）之前的偏移：前导 + ChirpGap。
    static var dataStartOffset: Int { preambleSamples + chirpGap }

    static func dataSymbols(for set: SpectralSet) -> Int { set.dataSymbols }

    static func dataSamples(for set: SpectralSet) -> Int {
        (1 + dataSymbols(for: set)) * symbolSamples
    }

    static func frameSamples(for set: SpectralSet) -> Int {
        preambleSamples + chirpGap + dataSamples(for: set)
    }

    static func expectedSeconds(for config: ScanRunConfig) -> Double {
        let normalized = config.normalized
        let sets = normalized.activeSets
        let count = Double(sets.reduce(0) { $0 + frameSamples(for: $1) })
        let seconds = count * Double(normalized.packetsPerSet) / sampleRate
        return seconds * 1.10 + 1.5
    }

    static func plan(for set: SpectralSet) -> OFDMModem.Plan {
        WatercommsPhy.plan(for: set)
    }

    static func makeFrame(payload: UInt64, set: SpectralSet) -> [Float] {
        WatercommsPhy.makeFrame(payload: payload, set: set)
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
