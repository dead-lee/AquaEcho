import Foundation

/// 广义 Goertzel：对已知频率直接求能量，不用整段 FFT。
/// 同一窗长下能量可互相比较，因此信噪比和双频比与窗长无关。
enum Goertzel {
    static func power(samples: ArraySlice<Float>, sampleRate: Double, frequency: Double) -> Double {
        let count = samples.count
        guard count > 0, sampleRate > 0, frequency > 0 else { return 0 }
        let omega = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
        var previous = 0.0
        var previous2 = 0.0
        for sample in samples {
            let current = Double(sample) + coefficient * previous - previous2
            previous2 = previous
            previous = current
        }
        let energy = previous * previous + previous2 * previous2 - coefficient * previous * previous2
        return max(0, energy) / Double(count)
    }

    /// 远离 f0、f1 的几个频率，用来估计噪声底。
    static func noiseFrequencies(f0: Double, f1: Double, sampleRate: Double) -> [Double] {
        let nyquist = sampleRate * 0.46
        let offsets = [-2_500.0, -1_800.0, -1_200.0, 1_200.0, 1_800.0, 2_500.0]
        var picked: [Double] = []
        for base in [f0, f1] {
            for offset in offsets {
                let frequency = base + offset
                guard frequency > 400, frequency < nyquist else { continue }
                guard abs(frequency - f0) > 800, abs(frequency - f1) > 800 else { continue }
                if picked.allSatisfy({ abs($0 - frequency) > 200 }) {
                    picked.append(frequency)
                }
                if picked.count == 4 { return picked }
            }
        }
        return picked.isEmpty ? [1_000] : picked
    }
}
