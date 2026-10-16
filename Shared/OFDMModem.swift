import Foundation

/// watercomms 的数据通路：线性调频对齐，差分 BPSK-OFDM，循环前缀，频域均衡。
/// 载荷 bit 的排列不变。0 映射到子载波实部 +1，1 映射到 −1。
enum OFDMModem {
    static let playbackAmplitude: Float = 0.98

    struct Plan {
        var sampleRate: Double
        var ns: Int
        var cp: Int
        var gap: Int
        var chirp: [Float]
        var chirpEnergy: Double
        var chirpEnergyCoarse: Double
        var coarseStep: Int
        var coarseHop: Int
        var alignRadius: Int
        var carriers: [Int]
        var noiseBins: [Int]
        var trainingBits: [Bool]
        var trainingBody: [Float]
        var trainingEnergy: Double
        var dataCounts: [Int]
        var symbolSamples: Int
        var packetSamples: Int
    }

    struct SymbolReading {
        var snrDB: Double
        var ratioDB: Double
    }

    struct Demodulated {
        var bits: [Bool]
        var readings: [SymbolReading]
    }

    static func plan(f0: Double, f1: Double, config: TestConfig, bitCount: Int) -> Plan {
        let config = config.normalized
        let rate = config.sampleRate
        let ns = max(64, Int((config.symbolDurationMs / 1_000 * rate).rounded()))
        var cp = max(0, Int((config.cyclicPrefixMs / 1_000 * rate).rounded()))
        cp = min(cp, ns / 4)
        let gap = max(0, Int((config.silenceDurationMs / 1_000 * rate).rounded()))
        let chirpCount = max(1, Int((config.chirpDurationMs / 1_000 * rate).rounded()))
        let spacing = rate / Double(ns)
        var lowBin = Int((min(f0, f1) / spacing).rounded())
        var highBin = Int((max(f0, f1) / spacing).rounded()) - 1
        let nyquist = ns / 2 - 1
        lowBin = min(max(lowBin, 1), nyquist)
        highBin = min(max(highBin, lowBin), nyquist)
        let carriers = Array(lowBin...highBin)
        let noiseBins = noiseBins(around: lowBin...highBin, nyquist: nyquist)
        let training = trainingBits(count: carriers.count)
        let body = synthesize(bits: training, carriers: carriers, ns: ns)
        let dataCounts = split(bitCount: max(0, bitCount), carriers: carriers.count)
        let symbolSamples = cp + ns
        let packetSamples = chirpCount + gap + (1 + dataCounts.count) * symbolSamples
        let chirp = chirp(f0: min(f0, f1), f1: max(f0, f1), count: chirpCount, sampleRate: rate)
        return Plan(
            sampleRate: rate,
            ns: ns,
            cp: cp,
            gap: gap,
            chirp: chirp,
            chirpEnergy: energy(chirp, step: 1),
            chirpEnergyCoarse: energy(chirp, step: 4),
            coarseStep: 4,
            coarseHop: max(8, Int((0.0005 * rate).rounded())),
            alignRadius: max(cp, Int((0.002 * rate).rounded())),
            carriers: carriers,
            noiseBins: noiseBins,
            trainingBits: training,
            trainingBody: body,
            trainingEnergy: energy(body, step: 1),
            dataCounts: dataCounts,
            symbolSamples: symbolSamples,
            packetSamples: packetSamples
        )
    }

    static func signalSeconds(f0: Double, f1: Double, config: TestConfig) -> Double {
        let plan = plan(f0: f0, f1: f1, config: config, bitCount: PacketLayout.bitCount)
        return Double(plan.packetSamples) / config.normalized.sampleRate
    }

    static func render(bits: [Bool], f0: Double, f1: Double, config: TestConfig) -> [Float] {
        let plan = plan(f0: f0, f1: f1, config: config, bitCount: bits.count)
        var output: [Float] = []
        output.reserveCapacity(plan.packetSamples)
        output.append(contentsOf: plan.chirp)
        if plan.gap > 0 {
            output.append(contentsOf: repeatElement(0, count: plan.gap))
        }
        var previous = plan.trainingBits
        output.append(contentsOf: withPrefix(plan.trainingBody, cp: plan.cp))
        var cursor = 0
        for count in plan.dataCounts {
            var data = Array(bits[cursor..<(cursor + count)])
            cursor += count
            if data.count < plan.carriers.count {
                data.append(contentsOf: repeatElement(false, count: plan.carriers.count - data.count))
            }
            let transmitted = zip(previous, data).map { $0 != $1 }
            previous = transmitted
            let body = synthesize(bits: transmitted, carriers: plan.carriers, ns: plan.ns)
            output.append(contentsOf: withPrefix(body, cp: plan.cp))
        }
        return output
    }

    static func playback(bits: [Bool], f0: Double, f1: Double, config: TestConfig) -> [Float] {
        let config = config.normalized
        let tone = render(bits: bits, f0: f0, f1: f1, config: config)
        let lead = max(0, Int((config.leadSilenceMs / 1_000 * config.sampleRate).rounded()))
        let trail = max(0, Int((config.trailSilenceMs / 1_000 * config.sampleRate).rounded()))
        var output = [Float](repeating: 0, count: lead + tone.count + trail)
        if !tone.isEmpty {
            output.replaceSubrange(lead..<(lead + tone.count), with: tone)
        }
        return output
    }

    /// `symbolStart` 是第一个符号（含循环前缀）在 `window` 里的下标。
    static func demodulate(window: [Float], symbolStart: Int, plan: Plan) -> Demodulated? {
        let symbolCount = 1 + plan.dataCounts.count
        let end = symbolStart + symbolCount * plan.symbolSamples
        guard symbolStart >= 0, end <= window.count else { return nil }
        guard let training = spectrum(window: window, bodyStart: symbolStart + plan.cp, plan: plan) else { return nil }
        let weights = zip(plan.trainingBits, training.carriers).map { bit, bin in
            weight(sign: bit ? -1 : 1, bin: bin)
        }
        var previous = zip(training.carriers, weights).map { multiply($0, $1) }
        var bits: [Bool] = []
        bits.reserveCapacity(plan.dataCounts.reduce(0, +))
        var readings: [SymbolReading] = []
        for (index, count) in plan.dataCounts.enumerated() {
            let start = symbolStart + (index + 1) * plan.symbolSamples
            guard let spectrum = spectrum(window: window, bodyStart: start + plan.cp, plan: plan) else { return nil }
            let equalized = zip(spectrum.carriers, weights).map { multiply($0, $1) }
            for carrier in 0..<count {
                bits.append(isOne(equalized[carrier], previous: previous[carrier]))
            }
            previous = equalized
            readings.append(reading(signal: spectrum.carriers, noise: spectrum.noise))
        }
        guard bits.count == plan.dataCounts.reduce(0, +) else { return nil }
        return Demodulated(bits: bits, readings: readings)
    }

    private struct Bin {
        var re: Double
        var im: Double
        var power: Double { re * re + im * im }
    }

    private struct Spectrum {
        var carriers: [Bin]
        var noise: [Bin]
    }

    private static func spectrum(window: [Float], bodyStart: Int, plan: Plan) -> Spectrum? {
        let bodyEnd = bodyStart + plan.ns
        guard bodyStart >= 0, bodyEnd <= window.count else { return nil }
        let samples = window[bodyStart..<bodyEnd]
        return Spectrum(
            carriers: dft(samples, bins: plan.carriers),
            noise: dft(samples, bins: plan.noiseBins)
        )
    }

    private static func reading(signal: [Bin], noise: [Bin]) -> SymbolReading {
        let signalPower = signal.map(\.power)
        let noisePower = noise.map(\.power)
        let signalMean = mean(signalPower)
        let noiseMean = max(mean(noisePower), 1e-20)
        let weakest = signalPower.min() ?? signalMean
        let snr = (10 * log10(max(signalMean, 1e-20) / noiseMean)).clamped(to: -10...80)
        let ratio = (10 * log10(max(weakest, 1e-20) / noiseMean)).clamped(to: 0...60)
        return SymbolReading(snrDB: snr, ratioDB: ratio)
    }

    private static func dft(_ samples: ArraySlice<Float>, bins: [Int]) -> [Bin] {
        let count = samples.count
        guard count > 0 else { return Array(repeating: Bin(re: 0, im: 0), count: bins.count) }
        return bins.map { bin in
            let omega = 2 * Double.pi * Double(bin) / Double(count)
            let coefficient = 2 * cos(omega)
            var q1 = 0.0
            var q2 = 0.0
            for sample in samples {
                let q0 = Double(sample) + coefficient * q1 - q2
                q2 = q1
                q1 = q0
            }
            return Bin(re: q1 - q2 * cos(omega), im: q2 * sin(omega))
        }
    }

    private static func weight(sign: Double, bin: Bin) -> Bin {
        let power = bin.re * bin.re + bin.im * bin.im
        guard power > 1e-18 else { return Bin(re: 0, im: 0) }
        return Bin(re: sign * bin.re / power, im: -sign * bin.im / power)
    }

    private static func multiply(_ lhs: Bin, _ rhs: Bin) -> Bin {
        Bin(
            re: lhs.re * rhs.re - lhs.im * rhs.im,
            im: lhs.re * rhs.im + lhs.im * rhs.re
        )
    }

    /// 相位落在 ±90° 以外视为两个符号不同，差分编码下这就是数据 1。
    private static func isOne(_ current: Bin, previous: Bin) -> Bool {
        let real = current.re * previous.re + current.im * previous.im
        let imag = current.im * previous.re - current.re * previous.im
        guard abs(real) > 1e-18 || abs(imag) > 1e-18 else { return false }
        let phase = atan2(imag, real)
        return phase >= .pi / 2 || phase <= -.pi / 2
    }

    private static func synthesize(bits: [Bool], carriers: [Int], ns: Int) -> [Float] {
        var body = [Float](repeating: 0, count: ns)
        for (bit, bin) in zip(bits, carriers) {
            let sign: Float = bit ? -1 : 1
            let omega = 2 * Float.pi * Float(bin) / Float(ns)
            for index in 0..<ns {
                body[index] += sign * cos(omega * Float(index))
            }
        }
        var peak: Float = 0
        for sample in body {
            peak = max(peak, abs(sample))
        }
        guard peak > 0 else { return body }
        let gain = playbackAmplitude / peak
        for index in body.indices {
            body[index] *= gain
        }
        return body
    }

    private static func withPrefix(_ body: [Float], cp: Int) -> [Float] {
        guard cp > 0 else { return body }
        var output: [Float] = []
        output.reserveCapacity(cp + body.count)
        output.append(contentsOf: body[(body.count - cp)...])
        output.append(contentsOf: body)
        return output
    }

    private static func chirp(f0: Double, f1: Double, count: Int, sampleRate: Double) -> [Float] {
        guard count > 0, sampleRate > 0 else { return [] }
        var phase = 0.0
        var output: [Float] = []
        output.reserveCapacity(count)
        let twoPi = 2 * Double.pi
        for index in 0..<count {
            output.append(playbackAmplitude * Float(sin(phase)))
            let fraction = Double(index) / Double(count)
            let frequency = f0 + (f1 - f0) * fraction
            phase += twoPi * frequency / sampleRate
            if phase >= twoPi {
                phase -= twoPi
            }
        }
        return output
    }

    private static func trainingBits(count: Int) -> [Bool] {
        let pattern = Array("100000100001100010100111101000111001001011011101100110101011").map { $0 == "1" }
        guard !pattern.isEmpty else { return Array(repeating: false, count: count) }
        return (0..<count).map { pattern[$0 % pattern.count] }
    }

    private static func split(bitCount: Int, carriers: Int) -> [Int] {
        guard carriers > 0, bitCount > 0 else { return [] }
        var left = bitCount
        var counts: [Int] = []
        while left > 0 {
            let take = min(carriers, left)
            counts.append(take)
            left -= take
        }
        return counts
    }

    private static func noiseBins(around band: ClosedRange<Int>, nyquist: Int) -> [Int] {
        let offsets = [-8, -6, -4, 4, 6, 8]
        var bins: [Int] = []
        for edge in [band.lowerBound, band.upperBound] {
            for offset in offsets {
                let bin = edge + offset
                guard bin >= 1, bin <= nyquist, !band.contains(bin) else { continue }
                if !bins.contains(bin) {
                    bins.append(bin)
                }
            }
        }
        return bins.isEmpty ? [1] : bins
    }

    private static func energy(_ samples: [Float], step: Int) -> Double {
        let stride = max(1, step)
        var total = 0.0
        var index = 0
        while index < samples.count {
            let sample = Double(samples[index])
            total += sample * sample
            index += stride
        }
        return total
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
