import Foundation

/// 带间隔的脉宽键控。
/// 每个 bit 是 toneMs 的单音加 gapMs 的静音。0 用 f0，1 用 f1。单音没有淡入淡出。
enum CPFSKSynth {
    static let playbackAmplitude: Float = 0.98

    static func render(
        bits: [Bool],
        f0: Double,
        f1: Double,
        sampleRate: Double,
        toneMs: Double,
        gapMs: Double,
        amplitude: Float = playbackAmplitude
    ) -> [Float] {
        let toneCount = max(1, Int((toneMs / 1_000 * sampleRate).rounded()))
        let gapCount = max(0, Int((gapMs / 1_000 * sampleRate).rounded()))
        var phase = 0.0
        var output: [Float] = []
        output.reserveCapacity(max(0, bits.count) * (toneCount + gapCount))
        let twoPi = 2 * Double.pi
        for bit in bits {
            let frequency = bit ? f1 : f0
            let delta = twoPi * frequency / sampleRate
            for _ in 0..<toneCount {
                output.append(amplitude * Float(sin(phase)))
                phase += delta
                if phase >= twoPi {
                    phase -= twoPi
                }
            }
            if gapCount > 0 {
                output.append(contentsOf: repeatElement(0, count: gapCount))
            }
        }
        return output
    }

    static func playback(
        bits: [Bool],
        f0: Double,
        f1: Double,
        sampleRate: Double,
        toneMs: Double,
        gapMs: Double,
        leadMs: Double,
        trailMs: Double
    ) -> [Float] {
        let tone = render(
            bits: bits,
            f0: f0,
            f1: f1,
            sampleRate: sampleRate,
            toneMs: toneMs,
            gapMs: gapMs
        )
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
}
