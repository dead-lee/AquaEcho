import Accelerate
import Foundation

/// watercomms 的默认数据通路：1000–4000 Hz，naiser3 前导，差分 BPSK-OFDM，循环前缀。
/// 符号长度 960 点时，差分比特来自 Decoder_offline 的时域均衡（480 抽头，前看 100 点）。
/// 0 映射到子载波实部 +1，1 映射到 −1。卷积编码由调用方完成。
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
        let preamble = NaiserWaveform.samples
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
        let plan = plan(f0: f0, f1: f1, config: config, bitCount: ConvolutionalCode.encodedBitCount)
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
        let frequency = demodulateFrequency(window: window, symbolStart: symbolStart, plan: plan)
        guard let equalized = demodulateTimeEqualized(window: window, symbolStart: symbolStart, plan: plan) else {
            return frequency
        }
        guard let frequency else { return equalized }
        // 两条通路都解得出时，留编码比特离卷积码更近的那条。时域均衡只在它更干净时替换频域结果。
        if codedDisagreement(equalized) < codedDisagreement(frequency) {
            return equalized
        }
        return frequency
    }

    /// Decoder_offline.m 在 `differential_based_time = 1` 时用这条通路出比特。
    /// Ns=960 时 tap_num=480、offset=100、岭回归 1e-5。尾巴放不进窗口就交给频域均衡。
    private static func demodulateTimeEqualized(window: [Float], symbolStart: Int, plan: Plan) -> Demodulated? {
        guard plan.ns == 960 else { return nil }
        let tapCount = 480
        let offset = 100
        let symbolCount = 1 + plan.dataCounts.count
        let transmitted = synthesize(bits: plan.trainingBits, carriers: plan.carriers, ns: plan.ns)
        guard let training = equalizerInput(
            window: window,
            bodyStart: symbolStart + plan.cp,
            sampleCount: plan.ns,
            taps: tapCount,
            offset: offset
        ), let taps = timeEqualizerTaps(transmitted: transmitted, received: training, taps: tapCount) else {
            return nil
        }
        var carriers: [[Bin]] = []
        carriers.reserveCapacity(symbolCount)
        var readings: [SymbolReading] = []
        for index in 0..<symbolCount {
            let bodyStart = symbolStart + index * plan.symbolSamples + plan.cp
            guard let received = equalizerInput(
                window: window,
                bodyStart: bodyStart,
                sampleCount: plan.ns,
                taps: tapCount,
                offset: offset
            ), let raw = spectrum(window: window, bodyStart: bodyStart, plan: plan) else {
                return nil
            }
            let body = recover(received: received, taps: taps)
            guard body.count == plan.ns else { return nil }
            carriers.append(dft(body[...], bins: plan.carriers))
            if index > 0 {
                readings.append(reading(signal: raw.carriers, noise: raw.noise))
            }
        }
        return demodulateCarriers(carriers, readings: readings, plan: plan)
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

    private static func codedDisagreement(_ demodulated: Demodulated) -> Int {
        let recoded = ConvolutionalCode.encode(ConvolutionalCode.decode(demodulated.bits))
        return zip(demodulated.bits, recoded).reduce(0) { count, pair in
            count + (pair.0 == pair.1 ? 0 : 1)
        }
    }

    /// Time_equalizer_estimation.m：g = (MᵀM + λI)⁻¹ Mᵀ tx。M 的每一行是接收窗上一段长度为抽头数的样本。
    private static func timeEqualizerTaps(transmitted: [Float], received: [Float], taps: Int) -> [Double]? {
        let length = transmitted.count
        guard taps > 0, taps <= length, received.count == length + taps - 1 else { return nil }
        var gram = [Double](repeating: 0, count: taps * taps)
        var rhs = [Double](repeating: 0, count: taps)
        let receivedValues = received.map(Double.init)
        let transmittedValues = transmitted.map(Double.init)
        receivedValues.withUnsafeBufferPointer { receivedBuffer in
            transmittedValues.withUnsafeBufferPointer { transmittedBuffer in
                guard let samples = receivedBuffer.baseAddress, let reference = transmittedBuffer.baseAddress else { return }
                let count = vDSP_Length(length)
                for column in 0..<taps {
                    var projection = 0.0
                    vDSP_dotprD(samples + column, 1, reference, 1, &projection, count)
                    rhs[column] = projection
                    for row in 0...column {
                        var sum = 0.0
                        vDSP_dotprD(samples + row, 1, samples + column, 1, &sum, count)
                        gram[column * taps + row] = sum
                    }
                }
            }
        }
        let lambda = 1e-5
        for index in 0..<taps {
            gram[index * taps + index] += lambda
        }
        return solveUpperPositiveDefinite(gram: &gram, rhs: rhs, dimension: taps)
    }

    /// 解 A x = b。A 是列主序的上三角（含对角），对称正定。
    private static func solveUpperPositiveDefinite(gram: inout [Double], rhs: [Double], dimension: Int) -> [Double]? {
        guard gram.count == dimension * dimension, rhs.count == dimension else { return nil }
        for row in 0..<dimension {
            for column in row..<dimension {
                var sum = gram[row + column * dimension]
                for k in 0..<row {
                    sum -= gram[k + row * dimension] * gram[k + column * dimension]
                }
                if row == column {
                    guard sum > 0 else { return nil }
                    gram[row + column * dimension] = sum.squareRoot()
                } else {
                    let diagonal = gram[row + row * dimension]
                    guard diagonal > 0 else { return nil }
                    gram[row + column * dimension] = sum / diagonal
                }
            }
        }
        var forward = rhs
        for row in 0..<dimension {
            var sum = forward[row]
            for k in 0..<row {
                sum -= gram[k + row * dimension] * forward[k]
            }
            let diagonal = gram[row + row * dimension]
            guard diagonal > 0 else { return nil }
            forward[row] = sum / diagonal
        }
        var solution = forward
        for row in stride(from: dimension - 1, through: 0, by: -1) {
            var sum = solution[row]
            for column in (row + 1)..<dimension {
                sum -= gram[row + column * dimension] * solution[column]
            }
            let diagonal = gram[row + row * dimension]
            guard diagonal > 0 else { return nil }
            solution[row] = sum / diagonal
        }
        return solution
    }

    private static func recover(received: [Float], taps: [Double]) -> [Float] {
        let tapCount = taps.count
        let length = received.count - tapCount + 1
        guard length > 0 else { return [] }
        var output = [Float](repeating: 0, count: length)
        received.withUnsafeBufferPointer { receivedBuffer in
            guard let samples = receivedBuffer.baseAddress else { return }
            for index in 0..<length {
                var sum = 0.0
                for tap in 0..<tapCount {
                    sum += Double(samples[index + tap]) * taps[tap]
                }
                output[index] = Float(sum)
            }
        }
        return output
    }

    private static func equalizerInput(
        window: [Float],
        bodyStart: Int,
        sampleCount: Int,
        taps: Int,
        offset: Int
    ) -> [Float]? {
        let start = bodyStart - offset
        let count = sampleCount + taps - 1
        guard start >= 0, count > 0, start + count <= window.count else { return nil }
        return Array(window[start..<(start + count)])
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

    /// shuffleArray：种子是数据符号序号，从 0 起。随机数是 java.util.Random 的 48 位线性同余，不是 Swift 的生成器。
    static func interleave(_ bits: [Bool], symbolIndex: Int) -> [Bool] {
        let order = interleaveOrder(count: bits.count, symbolIndex: symbolIndex)
        return order.map { bits[$0] }
    }

    /// unshuffle：用同一序号再走一遍打乱，把位置映射还原。
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

    /// java.util.Random。种子先异或 0x5DEECE66D，再保留低 48 位。
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

    /// find_symbol.m：96 阶 Hamming 带通，低频比频带低 200 Hz，高频停在频带上沿。补偿群延迟后，下标与输入对齐。
    static func bandpass(_ samples: [Float], lowHz: Double, highHz: Double, sampleRate: Double) -> [Float] {
        guard samples.count > filterOrder, sampleRate > 0 else { return samples }
        let kernel = bandpassTaps(lowHz: lowHz, highHz: highHz, sampleRate: sampleRate).map { Float($0) }
        let outputCount = samples.count - kernel.count + 1
        guard outputCount > 0 else { return samples }
        var convolved = [Float](repeating: 0, count: outputCount)
        samples.withUnsafeBufferPointer { signalPointer in
            kernel.withUnsafeBufferPointer { kernelPointer in
                convolved.withUnsafeMutableBufferPointer { outputPointer in
                    guard let signalBase = signalPointer.baseAddress,
                          let kernelBase = kernelPointer.baseAddress,
                          let outputBase = outputPointer.baseAddress else { return }
                    vDSP_conv(
                        signalBase,
                        1,
                        kernelBase,
                        1,
                        outputBase,
                        1,
                        vDSP_Length(outputCount),
                        vDSP_Length(kernel.count)
                    )
                }
            }
        }
        // 对称 FIR 的群延迟是阶数的一半。补上这段延迟后，下标和输入采样对齐。
        var filtered = [Float](repeating: 0, count: samples.count)
        for index in convolved.indices {
            let aligned = index + filterDelay
            if aligned < filtered.count {
                filtered[aligned] = convolved[index]
            }
        }
        return filtered
    }

    /// 前导和带通后的录音做线性相关，对应 xcorr_helper。返回值的下标就是前导起点，只用于找正峰位置。
    static func correlate(signal: [Float], template: [Float]) -> [Float] {
        let count = signal.count - template.count + 1
        guard count > 0, !template.isEmpty else { return [] }
        var size = 1
        var power = 0
        let needed = signal.count + template.count - 1
        while size < needed {
            size <<= 1
            power += 1
            if power > 20 { return [] }
        }
        let log2n = vDSP_Length(power)
        guard let setup = fftSetup(log2n: log2n) else { return [] }
        var signalInReal = signal + [Float](repeating: 0, count: size - signal.count)
        var signalInImag = [Float](repeating: 0, count: size)
        var templateInReal = template + [Float](repeating: 0, count: size - template.count)
        var templateInImag = [Float](repeating: 0, count: size)
        var signalOutReal = [Float](repeating: 0, count: size)
        var signalOutImag = [Float](repeating: 0, count: size)
        var templateOutReal = [Float](repeating: 0, count: size)
        var templateOutImag = [Float](repeating: 0, count: size)

        func transform(_ direction: FFTDirection, _ inReal: inout [Float], _ inImag: inout [Float], _ outReal: inout [Float], _ outImag: inout [Float]) {
            inReal.withUnsafeMutableBufferPointer { inRealPointer in
                inImag.withUnsafeMutableBufferPointer { inImagPointer in
                    outReal.withUnsafeMutableBufferPointer { outRealPointer in
                        outImag.withUnsafeMutableBufferPointer { outImagPointer in
                            guard let inRealBase = inRealPointer.baseAddress,
                                  let inImagBase = inImagPointer.baseAddress,
                                  let outRealBase = outRealPointer.baseAddress,
                                  let outImagBase = outImagPointer.baseAddress else { return }
                            var input = DSPSplitComplex(realp: inRealBase, imagp: inImagBase)
                            var output = DSPSplitComplex(realp: outRealBase, imagp: outImagBase)
                            vDSP_fft_zop(setup, &input, 1, &output, 1, log2n, direction)
                        }
                    }
                }
            }
        }

        transform(FFTDirection(kFFTDirection_Forward), &signalInReal, &signalInImag, &signalOutReal, &signalOutImag)
        transform(FFTDirection(kFFTDirection_Forward), &templateInReal, &templateInImag, &templateOutReal, &templateOutImag)
        for index in 0..<size {
            let real = signalOutReal[index]
            let imag = signalOutImag[index]
            let kernelReal = templateOutReal[index]
            let kernelImag = templateOutImag[index]
            signalInReal[index] = real * kernelReal + imag * kernelImag
            signalInImag[index] = imag * kernelReal - real * kernelImag
        }
        transform(FFTDirection(kFFTDirection_Inverse), &signalInReal, &signalInImag, &signalOutReal, &signalOutImag)
        return Array(signalOutReal.prefix(count))
    }

    private static let fftLock = NSLock()
    private static var fftSetups: [vDSP_Length: FFTSetup] = [:]
    private static var bluesteinPlans: [Int: BluesteinPlan] = [:]
    private static var cachedPreambleCount = 0
    private static var cachedPreambleReal: [Float] = []
    private static var cachedPreambleImag: [Float] = []

    /// 9360 不是 2 的幂，vDSP 的任意长度 DFT 也不含因子 13。用 Bluestein 把精确 N 点变换换成 2 的幂 FFT。
    private struct BluesteinPlan {
        var size: Int
        var log2n: vDSP_Length
        var chirpReal: [Float]
        var chirpImag: [Float]
        var kernelReal: [Float]
        var kernelImag: [Float]
    }

    private static func preambleSpectrum(_ preamble: [Float]) -> (real: [Float], imag: [Float]) {
        fftLock.lock()
        if cachedPreambleCount == preamble.count, cachedPreambleReal.count == preamble.count {
            let real = cachedPreambleReal
            let imag = cachedPreambleImag
            fftLock.unlock()
            return (real, imag)
        }
        fftLock.unlock()
        let spectrum = forwardDFT(preamble, [Float](repeating: 0, count: preamble.count))
        fftLock.lock()
        cachedPreambleCount = preamble.count
        cachedPreambleReal = spectrum.real
        cachedPreambleImag = spectrum.imag
        fftLock.unlock()
        return spectrum
    }

    static func spectrum(_ samples: [Float]) -> (real: [Float], imag: [Float]) {
        forwardDFT(samples, [Float](repeating: 0, count: samples.count))
    }

    static func magnitudeSpectrum(_ samples: [Float]) -> [Double] {
        let spectrum = spectrum(samples)
        return zip(spectrum.real, spectrum.imag).map { real, imag in
            Double((real * real + imag * imag).squareRoot())
        }
    }

    private static func forwardDFT(_ realIn: [Float], _ imagIn: [Float]) -> (real: [Float], imag: [Float]) {
        transformDFT(realIn, imagIn, inverse: false)
    }

    private static func inverseDFT(_ realIn: [Float], _ imagIn: [Float]) -> (real: [Float], imag: [Float]) {
        transformDFT(realIn, imagIn, inverse: true)
    }

    /// 逆变换用共轭输入再共轭输出，尺度不影响后面的归一化冲激峰。
    private static func transformDFT(_ realIn: [Float], _ imagIn: [Float], inverse: Bool) -> (real: [Float], imag: [Float]) {
        let length = realIn.count
        guard length > 1, imagIn.count == length else { return (realIn, imagIn) }
        let plan = bluesteinPlan(length: length)
        let inputReal = realIn
        let inputImag = inverse ? imagIn.map { -$0 } : imagIn
        var paddedReal = [Float](repeating: 0, count: plan.size)
        var paddedImag = [Float](repeating: 0, count: plan.size)
        for index in 0..<length {
            let chirpReal = plan.chirpReal[index]
            let chirpImag = plan.chirpImag[index]
            let sampleReal = inputReal[index]
            let sampleImag = inputImag[index]
            paddedReal[index] = sampleReal * chirpReal - sampleImag * chirpImag
            paddedImag[index] = sampleReal * chirpImag + sampleImag * chirpReal
        }
        let convolved = circularConvolve(
            paddedReal,
            paddedImag,
            kernelReal: plan.kernelReal,
            kernelImag: plan.kernelImag,
            log2n: plan.log2n
        )
        var outReal = [Float](repeating: 0, count: length)
        var outImag = [Float](repeating: 0, count: length)
        for index in 0..<length {
            let chirpReal = plan.chirpReal[index]
            let chirpImag = plan.chirpImag[index]
            let sampleReal = convolved.real[index]
            let sampleImag = convolved.imag[index]
            outReal[index] = sampleReal * chirpReal - sampleImag * chirpImag
            outImag[index] = sampleReal * chirpImag + sampleImag * chirpReal
        }
        if inverse {
            return (outReal, outImag.map { -$0 })
        }
        return (outReal, outImag)
    }

    private static func bluesteinPlan(length: Int) -> BluesteinPlan {
        fftLock.lock()
        if let plan = bluesteinPlans[length] {
            fftLock.unlock()
            return plan
        }
        fftLock.unlock()
        let plan = makeBluesteinPlan(length: length)
        fftLock.lock()
        if let existing = bluesteinPlans[length] {
            fftLock.unlock()
            return existing
        }
        bluesteinPlans[length] = plan
        fftLock.unlock()
        return plan
    }

    private static func makeBluesteinPlan(length: Int) -> BluesteinPlan {
        var size = 1
        var power = 0
        while size < length * 2 - 1 {
            size <<= 1
            power += 1
        }
        let log2n = vDSP_Length(power)
        var chirpReal = [Float](repeating: 0, count: length)
        var chirpImag = [Float](repeating: 0, count: length)
        var kernelReal = [Float](repeating: 0, count: size)
        var kernelImag = [Float](repeating: 0, count: size)
        for index in 0..<length {
            let turns = Double(index * index) / (2 * Double(length))
            let wrapped = (turns - turns.rounded(.towardZero)) * 2 * Double.pi
            let real = Float(cos(wrapped))
            let imag = Float(-sin(wrapped))
            chirpReal[index] = real
            chirpImag[index] = imag
            kernelReal[index] = real
            kernelImag[index] = -imag
            if index > 0 {
                kernelReal[size - index] = real
                kernelImag[size - index] = -imag
            }
        }
        var kernelOutReal = [Float](repeating: 0, count: size)
        var kernelOutImag = [Float](repeating: 0, count: size)
        splitTransform(
            FFTDirection(kFFTDirection_Forward),
            &kernelReal,
            &kernelImag,
            &kernelOutReal,
            &kernelOutImag,
            log2n: log2n
        )
        return BluesteinPlan(
            size: size,
            log2n: log2n,
            chirpReal: chirpReal,
            chirpImag: chirpImag,
            kernelReal: kernelOutReal,
            kernelImag: kernelOutImag
        )
    }

    /// `kernel` 已经是 chirp 核的正变换，这里只变换输入，相乘后再逆变换。
    private static func circularConvolve(
        _ leftReal: [Float],
        _ leftImag: [Float],
        kernelReal: [Float],
        kernelImag: [Float],
        log2n: vDSP_Length
    ) -> (real: [Float], imag: [Float]) {
        let size = leftReal.count
        var leftInReal = leftReal
        var leftInImag = leftImag
        var leftOutReal = [Float](repeating: 0, count: size)
        var leftOutImag = [Float](repeating: 0, count: size)
        splitTransform(FFTDirection(kFFTDirection_Forward), &leftInReal, &leftInImag, &leftOutReal, &leftOutImag, log2n: log2n)
        for index in 0..<size {
            let real = leftOutReal[index]
            let imag = leftOutImag[index]
            leftInReal[index] = real * kernelReal[index] - imag * kernelImag[index]
            leftInImag[index] = real * kernelImag[index] + imag * kernelReal[index]
        }
        splitTransform(FFTDirection(kFFTDirection_Inverse), &leftInReal, &leftInImag, &leftOutReal, &leftOutImag, log2n: log2n)
        return (leftOutReal, leftOutImag)
    }

    private static func splitTransform(
        _ direction: FFTDirection,
        _ inReal: inout [Float],
        _ inImag: inout [Float],
        _ outReal: inout [Float],
        _ outImag: inout [Float],
        log2n: vDSP_Length
    ) {
        guard let setup = fftSetup(log2n: log2n) else { return }
        inReal.withUnsafeMutableBufferPointer { inRealPointer in
            inImag.withUnsafeMutableBufferPointer { inImagPointer in
                outReal.withUnsafeMutableBufferPointer { outRealPointer in
                    outImag.withUnsafeMutableBufferPointer { outImagPointer in
                        guard let inRealBase = inRealPointer.baseAddress,
                              let inImagBase = inImagPointer.baseAddress,
                              let outRealBase = outRealPointer.baseAddress,
                              let outImagBase = outImagPointer.baseAddress else { return }
                        var input = DSPSplitComplex(realp: inRealBase, imagp: inImagBase)
                        var output = DSPSplitComplex(realp: outRealBase, imagp: outImagBase)
                        vDSP_fft_zop(setup, &input, 1, &output, 1, log2n, direction)
                    }
                }
            }
        }
    }

    /// Swift 的 `vDSP.FFT` 实际只变换 2^(log2n-1) 点，超过 65536 的延迟会变成 0。这里直接用 C 接口。
    private static func fftSetup(log2n: vDSP_Length) -> FFTSetup? {
        fftLock.lock()
        defer { fftLock.unlock() }
        if let setup = fftSetups[log2n] { return setup }
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        fftSetups[log2n] = setup
        return setup
    }

    /// find_symbol.m 的离线同步。相关峰只是入口：先向前最多 960 点，取仍超过峰值 0.4 倍的最早位置，
    /// 再从前 300 点起取一段和前导等长的录音做信道估计，用最早的冲激峰当作前导起点。
    /// 信道估计只用 `lowHz...highHz`，探测时是候选频段，数据时是这次选中的频段。
    /// find_symbol 里加回的 10000 点只是因为他们先裁掉了文件开头，这里的下标已经在整段录音上。
    static func earliestArrival(
        filtered: [Float],
        correlation: [Float],
        peakIndex: Int,
        preamble: [Float],
        sampleRate: Double,
        lowHz: Double,
        highHz: Double
    ) -> Int {
        guard correlation.indices.contains(peakIndex), preamble.count > 1, sampleRate > 0 else { return peakIndex }
        let threshold = correlation[peakIndex] * 0.4
        var leading = peakIndex
        let seekFrom = max(0, peakIndex - 960)
        if threshold > 0 {
            for index in seekFrom...peakIndex where correlation[index] > threshold {
                leading = index
                break
            }
        }
        let windowStart = leading - 300
        let length = preamble.count
        guard windowStart >= 0, windowStart + length <= filtered.count else { return leading }
        let segment = Array(filtered[windowStart..<(windowStart + length)])
        let received = forwardDFT(segment, [Float](repeating: 0, count: length))
        let transmitted = preambleSpectrum(preamble)
        var channelReal = [Float](repeating: 0, count: length)
        var channelImag = [Float](repeating: 0, count: length)
        let delta = sampleRate / Double(length)
        let begin = Int((min(lowHz, highHz) / delta).rounded()) - 1
        let end = Int((max(lowHz, highHz) / delta).rounded()) - 1
        guard begin >= 0, end < length, begin <= end else { return leading }
        var peakMagnitude = Float(0)
        for bin in begin...end {
            let magnitude = (transmitted.real[bin] * transmitted.real[bin] + transmitted.imag[bin] * transmitted.imag[bin]).squareRoot()
            if magnitude > peakMagnitude { peakMagnitude = magnitude }
        }
        let floor = peakMagnitude * 1e-4
        for bin in begin...end {
            let kernelReal = transmitted.real[bin]
            let kernelImag = transmitted.imag[bin]
            let magnitude = (kernelReal * kernelReal + kernelImag * kernelImag).squareRoot()
            if magnitude < floor { continue }
            let denominator = magnitude * magnitude
            let real = received.real[bin]
            let imag = received.imag[bin]
            channelReal[bin] = (real * kernelReal + imag * kernelImag) / denominator
            channelImag[bin] = (imag * kernelReal - real * kernelImag) / denominator
        }
        let response = inverseDFT(channelReal, channelImag)
        var magnitude = [Double](repeating: 0, count: length)
        var highest = 0.0
        for index in 0..<length {
            let value = Double(response.real[index] * response.real[index] + response.imag[index] * response.imag[index]).squareRoot()
            magnitude[index] = value
            if value > highest { highest = value }
        }
        guard highest > 0 else { return leading }
        let path = earliestImpulse(magnitude, peak: highest)
        return min(max(0, windowStart + path), filtered.count - 1)
    }

    /// channe_look_back：噪声门限是尾部均值的 1.5 倍再加 0.15，在最高峰及其后 10 点之前取最早的峰。返回值按 Matlab 下标，第一点是 1。
    private static func earliestImpulse(_ magnitude: [Double], peak: Double) -> Int {
        let normalized = magnitude.map { $0 / peak }
        let tailCount = min(501, normalized.count)
        let tail = normalized.suffix(tailCount)
        let noise = tail.reduce(0, +) / Double(tailCount) * 1.5 + 0.15
        let strongest = normalized.indices.max { normalized[$0] < normalized[$1] } ?? 0
        let slice = min(normalized.count, strongest + 11)
        var peaks: [(index: Int, height: Double)] = []
        for index in 0..<slice {
            let value = normalized[index]
            guard value >= noise else { continue }
            let left = index > 0 ? normalized[index - 1] : value - 1
            let right = index + 1 < slice ? normalized[index + 1] : value - 1
            if value > left && value > right {
                peaks.append((index, value))
            }
        }
        var kept: [Int] = []
        var remaining = peaks
        while !remaining.isEmpty {
            let best = remaining.max { $0.height < $1.height }!
            kept.append(best.index)
            remaining.removeAll { abs($0.index - best.index) < 5 }
        }
        let earliest = kept.min() ?? strongest
        return earliest + 1
    }

    /// Naiser_check_valid：在相关峰前后 1200 点、步长 8 上算差分相关。
    /// 得分达到 0.6 才算通过。返回的 start 是得分平台的后沿，供核对；符号起点用 earliestArrival。
    static func naiserLock(samples: [Float], peakIndex: Int) -> (start: Int, score: Double)? {
        let preambleLength = naiserPN.count * (naiserNu + naiserN0)
        let from = max(0, peakIndex - naiserWindow)
        let to = min(peakIndex + naiserWindow, samples.count - preambleLength)
        guard from <= to else { return nil }
        var scores: [(index: Int, score: Double)] = []
        scores.reserveCapacity((to - from) / naiserStep + 2)
        var index = from
        var bestScore = -Double.infinity
        while index <= to {
            let score = naiserMetric(samples, start: index)
            if score > bestScore {
                bestScore = score
            }
            scores.append((index, score))
            index += naiserStep
        }
        guard bestScore >= naiserThreshold, !scores.isEmpty else { return nil }
        let floor = bestScore * 0.995
        let start = scores.reduce(scores[0].index) { edge, sample in
            sample.score >= floor ? max(edge, sample.index) : edge
        }
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
