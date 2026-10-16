import Accelerate
import Foundation

/// watercomms 的数据通路：Naiser 前导对齐，差分 BPSK-OFDM，循环前缀，频域均衡。
/// 载荷 bit 的排列不变。0 映射到子载波实部 +1，1 映射到 −1。
enum OFDMModem {
    static let playbackAmplitude: Float = 0.98
    /// Naiser.java 的 PN、Nu、N0。8 段有用信号之间和末尾各留 N0 点静音。
    static let naiserPN: [Float] = [1, -1, -1, -1, -1, -1, 1, -1]
    static let naiserNu = 960
    static let naiserN0 = 240
    static let naiserThreshold = 0.6
    static let naiserWindow = 1_200
    static let naiserStep = 8
    /// find_symbol.m 的 fir1 阶数，群延迟是阶数的一半。
    static let filterOrder = 96
    static let filterDelay = filterOrder / 2

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

    static func plan(f0: Double, f1: Double, config: TestConfig, bitCount: Int) -> Plan {
        let config = config.normalized
        let rate = config.sampleRate
        let ns = max(64, Int((config.symbolDurationMs / 1_000 * rate).rounded()))
        var cp = max(0, Int((config.cyclicPrefixMs / 1_000 * rate).rounded()))
        cp = min(cp, ns / 4)
        let gap = max(0, Int((config.silenceDurationMs / 1_000 * rate).rounded()))
        let spacing = rate / Double(ns)
        var lowBin = Int((min(f0, f1) / spacing).rounded())
        var highBin = Int((max(f0, f1) / spacing).rounded()) - 1
        let nyquist = ns / 2 - 1
        lowBin = min(max(lowBin, 1), nyquist)
        highBin = min(max(highBin, lowBin), nyquist)
        let carriers = Array(lowBin...highBin)
        let noiseBins = noiseBins(around: lowBin...highBin, nyquist: nyquist)
        let training = trainingBits(count: carriers.count)
        let dataCounts = split(bitCount: max(0, bitCount), carriers: carriers.count)
        let symbolSamples = cp + ns
        let lowHz = min(f0, f1)
        let highHz = max(f0, f1)
        let preamble = naiserPreamble(f0: lowHz, f1: highHz, sampleRate: rate)
        let packetSamples = preamble.count + gap + (1 + dataCounts.count) * symbolSamples
        return Plan(
            sampleRate: rate,
            ns: ns,
            cp: cp,
            gap: gap,
            preamble: preamble,
            lowHz: lowHz,
            highHz: highHz,
            coarseHop: max(8, Int((0.0005 * rate).rounded())),
            carriers: carriers,
            noiseBins: noiseBins,
            trainingBits: training,
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
        output.append(contentsOf: plan.preamble)
        if plan.gap > 0 {
            output.append(contentsOf: repeatElement(0, count: plan.gap))
        }
        var previous = plan.trainingBits
        let trainingBody = synthesize(bits: plan.trainingBits, carriers: plan.carriers, ns: plan.ns)
        output.append(contentsOf: withPrefix(trainingBody, cp: plan.cp))
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

    /// 带内等幅余弦重复 8 段，符号按 Naiser 的 PN，段间和末尾是 N0 点静音。
    private static func naiserPreamble(f0: Double, f1: Double, sampleRate: Double) -> [Float] {
        let spacing = sampleRate / Double(naiserNu)
        var lowBin = Int((f0 / spacing).rounded())
        var highBin = Int((f1 / spacing).rounded()) - 1
        let nyquist = naiserNu / 2 - 1
        lowBin = min(max(lowBin, 1), nyquist)
        highBin = min(max(highBin, lowBin), nyquist)
        let carriers = Array(lowBin...highBin)
        let base = synthesize(
            bits: Array(repeating: false, count: carriers.count),
            carriers: carriers,
            ns: naiserNu
        )
        var output: [Float] = []
        output.reserveCapacity(naiserPN.count * (naiserNu + naiserN0))
        for sign in naiserPN {
            for sample in base {
                output.append(sign * sample)
            }
            output.append(contentsOf: repeatElement(0, count: naiserN0))
        }
        return output
    }

    /// find_symbol.m：96 阶 Hamming 带通，低频比频带低 200 Hz，高频停在频带上沿。补偿群延迟后，下标与输入对齐。
    static func bandpass(_ samples: [Float], lowHz: Double, highHz: Double, sampleRate: Double) -> [Float] {
        guard samples.count > filterDelay, sampleRate > 0 else { return samples }
        let taps = bandpassTaps(lowHz: lowHz, highHz: highHz, sampleRate: sampleRate)
        var filtered = [Float](repeating: 0, count: samples.count)
        let order = taps.count - 1
        for index in samples.indices {
            var acc = 0.0
            let start = max(0, index - order)
            for tapIndex in start...index {
                acc += Double(samples[tapIndex]) * taps[index - tapIndex]
            }
            let aligned = index - filterDelay
            if aligned >= 0 {
                filtered[aligned] = Float(acc)
            }
        }
        return filtered
    }

    /// 前导和带通后的录音做线性相关，对应 xcorr_helper。返回值的下标就是前导起点，只用于找正峰位置。
    static func correlate(signal: [Float], template: [Float]) -> [Float] {
        let count = signal.count - template.count + 1
        guard count > 0, !template.isEmpty else { return [] }
        let size = 1 << Int(ceil(log2(Double(signal.count + template.count - 1))))
        let log2n = vDSP_Length(log2(Double(size)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return [] }
        var signalReal = signal + [Float](repeating: 0, count: size - signal.count)
        var signalImag = [Float](repeating: 0, count: size)
        var templateReal = template + [Float](repeating: 0, count: size - template.count)
        var templateImag = [Float](repeating: 0, count: size)
        signalReal.withUnsafeMutableBufferPointer { signalRealPointer in
            signalImag.withUnsafeMutableBufferPointer { signalImagPointer in
                templateReal.withUnsafeMutableBufferPointer { templateRealPointer in
                    templateImag.withUnsafeMutableBufferPointer { templateImagPointer in
                        guard let signalRealBase = signalRealPointer.baseAddress,
                              let signalImagBase = signalImagPointer.baseAddress,
                              let templateRealBase = templateRealPointer.baseAddress,
                              let templateImagBase = templateImagPointer.baseAddress else { return }
                        var signalSplit = DSPSplitComplex(realp: signalRealBase, imagp: signalImagBase)
                        var templateSplit = DSPSplitComplex(realp: templateRealBase, imagp: templateImagBase)
                        fft.forward(input: signalSplit, output: &signalSplit)
                        fft.forward(input: templateSplit, output: &templateSplit)
                        for index in 0..<size {
                            let real = signalRealPointer[index]
                            let imag = signalImagPointer[index]
                            let kernelReal = templateRealPointer[index]
                            let kernelImag = templateImagPointer[index]
                            signalRealPointer[index] = real * kernelReal + imag * kernelImag
                            signalImagPointer[index] = imag * kernelReal - real * kernelImag
                        }
                        fft.inverse(input: signalSplit, output: &signalSplit)
                    }
                }
            }
        }
        return Array(signalReal.prefix(count))
    }

    /// Naiser_check_valid：在相关峰前后 1200 点里用步长 8 算差分相关，过 0.6 后取 85% 峰宽的中点。
    static func naiserLock(samples: [Float], peakIndex: Int) -> (start: Int, score: Double)? {
        let preambleLength = naiserPN.count * (naiserNu + naiserN0)
        let from = max(0, peakIndex - naiserWindow)
        let to = min(peakIndex + naiserWindow, samples.count - preambleLength)
        guard from <= to else { return nil }
        var scores: [(index: Int, score: Double)] = []
        scores.reserveCapacity((to - from) / naiserStep + 2)
        var index = from
        var bestOffset = 0
        var bestScore = -Double.infinity
        while index <= to {
            let score = naiserMetric(samples, start: index)
            if score > bestScore {
                bestScore = score
                bestOffset = scores.count
            }
            scores.append((index, score))
            index += naiserStep
        }
        guard bestScore >= naiserThreshold, !scores.isEmpty else { return nil }
        let height = bestScore * 0.85
        var left = bestOffset
        var right = bestOffset
        var cursor = bestOffset
        while cursor + 1 < scores.count {
            if scores[cursor].score >= height, scores[cursor + 1].score <= height {
                right = cursor
                break
            }
            cursor += 1
        }
        cursor = bestOffset
        while cursor > 0 {
            if scores[cursor].score >= height, scores[cursor - 1].score <= height {
                left = cursor
                break
            }
            cursor -= 1
        }
        let start = (scores[left].index + scores[right].index) / 2
        return (start, bestScore)
    }

    /// Naiser_corr 的单点：Pd/Rd/(L-1)*L。连续两段同号或反号都按 PN 乘积抵消。
    static func naiserMetric(_ samples: [Float], start: Int) -> Double {
        let block = naiserNu + naiserN0
        let length = naiserPN.count * block
        guard start >= 0, start + length <= samples.count else { return 0 }
        var matched = 0.0
        var energy = 0.0
        for index in 0..<(naiserPN.count - 1) {
            let sign = Double(naiserPN[index] * naiserPN[index + 1])
            let first = start + index * block + naiserN0
            let second = start + (index + 1) * block + naiserN0
            var dot = 0.0
            var secondEnergy = 0.0
            for sample in 0..<naiserNu {
                let left = Double(samples[first + sample])
                let right = Double(samples[second + sample])
                dot += left * right
                secondEnergy += right * right
            }
            matched += sign * dot
            if index == 0 {
                var firstEnergy = 0.0
                for sample in 0..<naiserNu {
                    let left = Double(samples[first + sample])
                    firstEnergy += left * left
                }
                energy += firstEnergy + secondEnergy
            } else {
                energy += secondEnergy
            }
        }
        guard energy > 1e-12 else { return 0 }
        return matched / energy / Double(naiserPN.count - 1) * Double(naiserPN.count)
    }

    private static func bandpassTaps(lowHz: Double, highHz: Double, sampleRate: Double) -> [Double] {
        let nyquist = sampleRate / 2
        let low = min(max(lowHz - 200, 50), nyquist - 200)
        let high = min(max(highHz, low + 100), nyquist - 50)
        let order = filterOrder
        var taps = [Double](repeating: 0, count: order + 1)
        let lowAngle = (low / nyquist) * Double.pi
        let highAngle = (high / nyquist) * Double.pi
        let center = order / 2
        for index in 0...order {
            let offset = index - center
            let window = 0.54 - 0.46 * cos(2 * Double.pi * Double(index) / Double(order))
            if offset == 0 {
                taps[index] = (highAngle - lowAngle) / Double.pi * window
            } else {
                let numerator = sin(highAngle * Double(offset)) - sin(lowAngle * Double(offset))
                taps[index] = numerator / (Double.pi * Double(offset)) * window
            }
        }
        let mid = (low + high) / 2
        let omega = 2 * Double.pi * mid / sampleRate
        var real = 0.0
        var imag = 0.0
        for index in taps.indices {
            real += taps[index] * cos(omega * Double(index))
            imag -= taps[index] * sin(omega * Double(index))
        }
        let gain = (real * real + imag * imag).squareRoot()
        guard gain > 1e-12 else { return taps }
        for index in taps.indices {
            taps[index] /= gain
        }
        return taps
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
