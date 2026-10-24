import Foundation

/// 扫描测试用的差分 BPSK-OFDM 调制/解调。
/// 只保留频域差分通路：训练符号做单抽头均衡，数据符号相对前一个符号解相位。
enum OFDMConstants {
    static let noiseBinOffsets = [-8, -6, -4, 4, 6, 8]
    static let coarseHopMin = 8
    static let coarseHopSeconds = 0.0005
}

enum OFDMModem {
    static let playbackAmplitude: Float = 0.98

    struct Plan {
        var sampleRate: Double
        var ns: Int
        var cp: Int
        var gap: Int
        var preamble: [Float]
        var lowHz: Double
        var highHz: Double
        var coarseHop: Int
        var carriers: [Int]
        var noiseBins: [Int]
        var trainingBits: [Bool]
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

    /// 显式子载波集合的计划。扫描模式前导为空（标记音负责同步），间隔为 0。
    static func plan(
        carriers: [Int],
        sampleRate: Double,
        ns: Int,
        cp: Int,
        preamble: [Float],
        gap: Int,
        bitCount: Int
    ) -> Plan {
        let nyquist = ns / 2 - 1
        let bins = carriers.filter { $0 >= 1 && $0 <= nyquist }
        let lowBin = bins.min() ?? 1
        let highBin = bins.max() ?? 1
        let training = trainingBits(count: bins.count)
        let dataCounts = split(bitCount: max(0, bitCount), carriers: bins.count)
        let noise = noiseBins(around: lowBin...highBin, nyquist: nyquist)
        let spacing = sampleRate / Double(ns)
        let symbolSamples = ns + cp
        return Plan(
            sampleRate: sampleRate,
            ns: ns,
            cp: cp,
            gap: gap,
            preamble: preamble,
            lowHz: Double(lowBin) * spacing,
            highHz: Double(highBin + 1) * spacing,
            coarseHop: max(OFDMConstants.coarseHopMin, Int((OFDMConstants.coarseHopSeconds * sampleRate).rounded())),
            carriers: bins,
            noiseBins: noise,
            trainingBits: training,
            dataCounts: dataCounts,
            symbolSamples: symbolSamples,
            packetSamples: preamble.count + gap + (1 + dataCounts.count) * symbolSamples
        )
    }

    /// 渲染训练符号 + 数据符号；不负责标记音和尾静音。
    static func render(bits: [Bool], plan: Plan) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(plan.packetSamples)
        output.append(contentsOf: plan.preamble)
        if plan.gap > 0 {
            output.append(contentsOf: repeatElement(0, count: plan.gap))
        }
        var previous = plan.trainingBits
        let trainingBody = synthesize(bits: plan.trainingBits, carriers: plan.carriers, ns: plan.ns)
        output.append(contentsOf: withPrefix(trainingBody, cp: plan.cp))
        var cursor = 0
        for (symbolIndex, count) in plan.dataCounts.enumerated() {
            var data = Array(bits[cursor..<(cursor + count)])
            cursor += count
            if data.count < plan.carriers.count {
                data.append(contentsOf: repeatElement(false, count: plan.carriers.count - data.count))
            }
            let arranged = interleave(data, symbolIndex: symbolIndex)
            let transmitted = zip(previous, arranged).map { $0 != $1 }
            previous = transmitted
            let body = synthesize(bits: transmitted, carriers: plan.carriers, ns: plan.ns)
            output.append(contentsOf: withPrefix(body, cp: plan.cp))
        }
        return output
    }

    static func demodulateFrequencyOnly(window: [Float], symbolStart: Int, plan: Plan) -> Demodulated? {
        demodulateFrequency(window: window, symbolStart: symbolStart, plan: plan)
    }

    private static func demodulateFrequency(window: [Float], symbolStart: Int, plan: Plan) -> Demodulated? {
        let symbolCount = 1 + plan.dataCounts.count
        let end = symbolStart + symbolCount * plan.symbolSamples
        guard symbolStart >= 0, end <= window.count else { return nil }
        guard let training = spectrum(window: window, bodyStart: symbolStart + plan.cp, plan: plan) else { return nil }
        let weights = zip(plan.trainingBits, training.carriers).map { bit, bin in
            weight(sign: bit ? -1 : 1, bin: bin)
        }
        var carriers: [[Bin]] = [zip(training.carriers, weights).map { multiply($0, $1) }]
        var readings: [SymbolReading] = []
        for index in 0..<plan.dataCounts.count {
            let start = symbolStart + (index + 1) * plan.symbolSamples
            guard let spectrum = spectrum(window: window, bodyStart: start + plan.cp, plan: plan) else { return nil }
            carriers.append(zip(spectrum.carriers, weights).map { multiply($0, $1) })
            readings.append(reading(signal: spectrum.carriers, noise: spectrum.noise))
        }
        return demodulateCarriers(carriers, readings: readings, plan: plan)
    }

    private static func demodulateCarriers(_ carriers: [[Bin]], readings: [SymbolReading], plan: Plan) -> Demodulated? {
        guard carriers.count == plan.dataCounts.count + 1 else { return nil }
        var previous = carriers[0]
        var bits: [Bool] = []
        bits.reserveCapacity(plan.dataCounts.reduce(0, +))
        for (index, count) in plan.dataCounts.enumerated() {
            let symbolBits = zip(carriers[index + 1], previous).map { isOne($0, previous: $1) }
            bits.append(contentsOf: deinterleave(symbolBits, symbolIndex: index).prefix(count))
            previous = carriers[index + 1]
        }
        guard bits.count == plan.dataCounts.reduce(0, +), readings.count == plan.dataCounts.count else { return nil }
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
        let power = bin.power
        guard power > 1e-18 else { return Bin(re: 0, im: 0) }
        return Bin(re: sign * bin.re / power, im: -sign * bin.im / power)
    }

    private static func multiply(_ lhs: Bin, _ rhs: Bin) -> Bin {
        Bin(
            re: lhs.re * rhs.re - lhs.im * rhs.im,
            im: lhs.re * rhs.im + lhs.im * rhs.re
        )
    }

    /// 每个数据符号用符号序号作为 java.util.Random 的种子做 Fisher-Yates 打乱。
    static func interleave(_ bits: [Bool], symbolIndex: Int) -> [Bool] {
        let order = interleaveOrder(count: bits.count, symbolIndex: symbolIndex)
        return order.map { bits[$0] }
    }

    static func deinterleave(_ bits: [Bool], symbolIndex: Int) -> [Bool] {
        let order = interleaveOrder(count: bits.count, symbolIndex: symbolIndex)
        var restored = [Bool](repeating: false, count: bits.count)
        for position in bits.indices {
            restored[order[position]] = bits[position]
        }
        return restored
    }

    static func interleaveOrder(count: Int, symbolIndex: Int) -> [Int] {
        var order = Array(0..<count)
        guard count > 1 else { return order }
        var random = JavaRandom(seed: symbolIndex)
        var index = count - 1
        while index > 0 {
            let choice = random.nextInt(index + 1)
            order.swapAt(choice, index)
            index -= 1
        }
        return order
    }

    private struct JavaRandom {
        private var seed: UInt64

        init(seed: Int) {
            let value = UInt64(bitPattern: Int64(seed))
            self.seed = (value ^ 0x5DEECE66D) & 0xFFFFFFFFFFFF
        }

        private mutating func next(bits: Int) -> Int32 {
            seed = (seed &* 0x5DEECE66D &+ 0xB) & 0xFFFFFFFFFFFF
            return Int32(truncatingIfNeeded: seed >> UInt64(48 - bits))
        }

        mutating func nextInt(_ bound: Int) -> Int {
            let bound = Int32(bound)
            var sample = next(bits: 31)
            let mask = bound &- 1
            if bound & mask == 0 {
                sample = Int32(truncatingIfNeeded: (Int64(bound) * Int64(sample)) >> 31)
            } else {
                var draw = sample
                sample = draw % bound
                while draw &- sample &+ mask < 0 {
                    draw = next(bits: 31)
                    sample = draw % bound
                }
            }
            return Int(sample)
        }
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
        var bins: [Int] = []
        for edge in [band.lowerBound, band.upperBound] {
            for offset in OFDMConstants.noiseBinOffsets {
                let bin = edge + offset
                guard bin >= 1, bin <= nyquist, !band.contains(bin) else { continue }
                if !bins.contains(bin) {
                    bins.append(bin)
                }
            }
        }
        return bins.isEmpty ? [1] : bins
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
