import Foundation

/// 连续相位 2-FSK。
/// 比特 0 使用 f0，比特 1 使用 f1。相位在符号边界继续累加，不重置，因此切换频率时波形连续。
enum CPFSKSynth {
    static let playbackAmplitude: Float = 0.98

    static func render(
        bits: [Bool],
        f0: Double,
        f1: Double,
        symbolSeconds: Double,
        sampleRate: Double,
        amplitude: Float = playbackAmplitude
    ) -> [Float] {
        let samplesPerSymbol = max(1, Int((symbolSeconds * sampleRate).rounded()))
        var phase = 0.0
        var output: [Float] = []
        output.reserveCapacity(max(0, bits.count) * samplesPerSymbol)
        let twoPi = 2 * Double.pi
        for bit in bits {
            let frequency = bit ? f1 : f0
            let delta = twoPi * frequency / sampleRate
            for _ in 0..<samplesPerSymbol {
                output.append(amplitude * Float(sin(phase)))
                phase += delta
                if phase >= twoPi {
                    phase -= twoPi
                }
            }
        }
        return output
    }

    /// 两端各 2 ms 余弦淡入淡出，避免静音与纯音相接时的宽带咔嗒声。符号内部的相位仍然连续。
    static func playback(
        bits: [Bool],
        f0: Double,
        f1: Double,
        symbolSeconds: Double,
        sampleRate: Double,
        leadMs: Double,
        trailMs: Double
    ) -> [Float] {
        var tone = render(
            bits: bits,
            f0: f0,
            f1: f1,
            symbolSeconds: symbolSeconds,
            sampleRate: sampleRate
        )
        fadeEdges(&tone, sampleRate: sampleRate, seconds: 0.002)
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
