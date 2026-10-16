import Foundation

/// 带间隔的脉宽键控。
/// 每个 bit 固定为 40 ms 单音加 15 ms 静音。0 用 f0，1 用 f1。单音内部相位连续。
enum CPFSKSynth {
    static let playbackAmplitude: Float = 0.98
    static let toneMilliseconds = 40.0
    static let gapMilliseconds = 15.0

    static func render(
        bits: [Bool],
        f0: Double,
        f1: Double,
        sampleRate: Double,
        amplitude: Float = playbackAmplitude
    ) -> [Float] {
        let toneCount = max(1, Int((toneMilliseconds / 1_000 * sampleRate).rounded()))
        let gapCount = max(0, Int((gapMilliseconds / 1_000 * sampleRate).rounded()))
        var phase = 0.0
        var output: [Float] = []
        output.reserveCapacity(max(0, bits.count) * (toneCount + gapCount))
        let twoPi = 2 * Double.pi
        for bit in bits {
            let frequency = bit ? f1 : f0
            let delta = twoPi * frequency / sampleRate
            var tone: [Float] = []
            tone.reserveCapacity(toneCount)
            for _ in 0..<toneCount {
                tone.append(amplitude * Float(sin(phase)))
                phase += delta
                if phase >= twoPi {
                    phase -= twoPi
                }
            }
            fadeEdges(&tone, sampleRate: sampleRate, seconds: 0.002)
            output.append(contentsOf: tone)
            if gapCount > 0 {
                output.append(contentsOf: repeatElement(0, count: gapCount))
            }
        }
        return output
    }

    /// 两端各 2 ms 余弦淡入淡出已经加在每个单音上。这里只补前导和结尾静音。
    static func playback(
        bits: [Bool],
        f0: Double,
        f1: Double,
        sampleRate: Double,
        leadMs: Double,
        trailMs: Double
    ) -> [Float] {
        let tone = render(bits: bits, f0: f0, f1: f1, sampleRate: sampleRate)
        return padded(tone, leadMs: leadMs, trailMs: trailMs, sampleRate: sampleRate)
    }

    static func padded(_ tone: [Float], leadMs: Double, trailMs: Double, sampleRate: Double) -> [Float] {
        let lead = max(0, Int((leadMs / 1_000 * sampleRate).rounded()))
        let trail = max(0, Int((trailMs / 1_000 * sampleRate).rounded()))
        var output = [Float](repeating: 0, count: lead + tone.count + trail)
        if !tone.isEmpty {
            output.replaceSubrange(lead..<(lead + tone.count), with: tone)
        }
        return output
    }

    private static func fadeEdges(_ samples: inout [Float], sampleRate: Double, seconds: Double) {
        let count = min(samples.count / 2, Int(seconds * sampleRate))
        guard count > 1 else { return }
        for index in 0..<count {
            let window = Float(0.5 - 0.5 * cos(Double.pi * Double(index) / Double(count)))
            samples[index] *= window
            samples[samples.count - 1 - index] *= window
        }
    }
}
