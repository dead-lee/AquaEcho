import Foundation
import Accelerate

/// watercomms 对齐版 PHY：Naiser 结构前导 + 960 gap + 训练/数据符号，Ns=960、Cp=67。
/// 实时集合的前导按自己的频段生成。
enum WatercommsPhy {
    static let ns = 960
    static let cp = 67
    static let gap = 960
    /// 原版 1–4 kHz naiser3。实时目录不用它，同步带通测试还用。
    static var preamble: [Float] { WatercommsPreamble.samples }

    private static let bandPreambles: [String: [Float]] = {
        Dictionary(uniqueKeysWithValues: SpectralSet.all.map { set in
            let samples = (set.lowHz == 1_000 && set.highHz == 4_000)
                ? WatercommsPreamble.samples
                : synthesizedPreamble(lowHz: set.lowHz, highHz: set.highHz)
            return (set.id, samples)
        })
    }()

    static func preamble(for set: SpectralSet) -> [Float] {
        bandPreambles[set.id] ?? synthesizedPreamble(lowHz: set.lowHz, highHz: set.highHz)
    }

    /// watercomms 对 1–4 kHz 用 800–4000 Hz。通带是数据下沿减 200 Hz 到上沿。
    static func syncBand(for set: SpectralSet) -> (lowHz: Double, highHz: Double) {
        let low = max(50, set.lowHz - 200)
        let high = min(ScanProtocol.sampleRate / 2 - 100, set.highHz)
        return (low, high)
    }

    /// 8 段 960 点下扫，段间 240 点空白，符号与 naiser3 相同。长度 9360。
    private static func synthesizedPreamble(lowHz: Double, highHz: Double) -> [Float] {
        let chirpCount = 960
        let gapCount = 240
        let signs: [Float] = [1, -1, -1, -1, -1, -1, 1, -1]
        let chirp = downchirp(from: highHz, to: lowHz, count: chirpCount)
        var output: [Float] = []
        output.reserveCapacity(signs.count * chirpCount + (signs.count - 1) * gapCount)
        for (index, sign) in signs.enumerated() {
            if index > 0 {
                output.append(contentsOf: repeatElement(0, count: gapCount))
            }
            output.append(contentsOf: chirp.map { $0 * sign })
        }
        return output
    }

    private static func downchirp(from highHz: Double, to lowHz: Double, count: Int) -> [Float] {
        let sampleRate = ScanProtocol.sampleRate
        let duration = Double(count) / sampleRate
        var chirp = [Float](repeating: 0, count: count)
        var peak: Float = 0
        for index in 0..<count {
            let time = Double(index) / sampleRate
            let phase = 2 * Double.pi * (highHz * time + (lowHz - highHz) * time * time / (2 * duration))
            let sample = Float(sin(phase))
            chirp[index] = sample
            peak = max(peak, abs(sample))
        }
        let scale = 0.95 / max(peak, 1e-6)
        for index in chirp.indices {
            chirp[index] *= scale
        }
        return chirp
    }

    static func plan(for set: SpectralSet) -> OFDMModem.Plan {
        OFDMModem.plan(
            carriers: set.carriers,
            sampleRate: ScanProtocol.sampleRate,
            ns: ns,
            cp: cp,
            preamble: preamble(for: set),
            gap: gap,
            bitCount: ConvolutionalCode.encodedBitCount
        )
    }

    static func makeFrame(payload: UInt64, set: SpectralSet) -> [Float] {
        let bits = PacketLayout.bits(for: PacketLayout.data(from: payload))
        let coded = ConvolutionalCode.encode(bits)
        return OFDMModem.render(bits: coded, plan: plan(for: set))
    }

    struct PreamblePeak {
        var index: Int
        var score: Float
    }

    private static let fftLock = NSLock()
    private static var fftSetups: [Int: FFTSetup] = [:]
    private static var kernelSpectra: [String: (real: [Float], imag: [Float])] = [:]

    private static func cachedFFTSetup(log2n: Int) -> FFTSetup? {
        if let setup = fftSetups[log2n] { return setup }
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return nil }
        fftSetups[log2n] = setup
        return setup
    }

    /// 归一化互相关。lag 处的值是前导与 `signal[lag..<lag+P]` 的相关系数。
    /// `cacheKey` 给定时复用该前导的频谱。FFT 计划按长度复用，数值与每次新建相同。
    static func preambleScores(in signal: [Float], kernel: [Float]? = nil, cacheKey: String? = nil) -> [Float] {
        let kernel = kernel ?? preamble
        let sampleCount = signal.count
        let kernelCount = kernel.count
        let lags = sampleCount - kernelCount + 1
        guard kernelCount > 0, lags > 0 else { return [] }

        var kernelEnergy: Float = 0
        vDSP_svesq(kernel, 1, &kernelEnergy, vDSP_Length(kernelCount))
        guard kernelEnergy > 0 else { return [] }

        var fftLength = 1
        var log2n = 0
        let needed = sampleCount + kernelCount - 1
        while fftLength < needed {
            fftLength <<= 1
            log2n += 1
        }
        fftLock.lock()
        defer { fftLock.unlock() }
        guard let setup = cachedFFTSetup(log2n: log2n) else { return [] }

        var signalReal = [Float](repeating: 0, count: fftLength)
        var signalImag = [Float](repeating: 0, count: fftLength)
        signalReal.replaceSubrange(0..<sampleCount, with: signal)
        let spectrumKey = cacheKey.map { "\($0)#\(fftLength)" }
        var kernelReal: [Float]
        var kernelImag: [Float]
        let kernelIsSpectrum: Bool
        if let spectrumKey, let cached = kernelSpectra[spectrumKey] {
            kernelReal = cached.real
            kernelImag = cached.imag
            kernelIsSpectrum = true
        } else {
            kernelReal = [Float](repeating: 0, count: fftLength)
            kernelImag = [Float](repeating: 0, count: fftLength)
            kernelReal.replaceSubrange(0..<kernelCount, with: kernel)
            kernelIsSpectrum = false
        }

        var productReal = [Float](repeating: 0, count: fftLength)
        var productImag = [Float](repeating: 0, count: fftLength)
        signalReal.withUnsafeMutableBufferPointer { signalRealBuffer in
            signalImag.withUnsafeMutableBufferPointer { signalImagBuffer in
                kernelReal.withUnsafeMutableBufferPointer { kernelRealBuffer in
                    kernelImag.withUnsafeMutableBufferPointer { kernelImagBuffer in
                        productReal.withUnsafeMutableBufferPointer { productRealBuffer in
                            productImag.withUnsafeMutableBufferPointer { productImagBuffer in
                                var signalSplit = DSPSplitComplex(
                                    realp: signalRealBuffer.baseAddress!,
                                    imagp: signalImagBuffer.baseAddress!
                                )
                                var kernelSplit = DSPSplitComplex(
                                    realp: kernelRealBuffer.baseAddress!,
                                    imagp: kernelImagBuffer.baseAddress!
                                )
                                var productSplit = DSPSplitComplex(
                                    realp: productRealBuffer.baseAddress!,
                                    imagp: productImagBuffer.baseAddress!
                                )
                                vDSP_fft_zip(setup, &signalSplit, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                                if !kernelIsSpectrum {
                                    vDSP_fft_zip(setup, &kernelSplit, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                                }
                                // conj(kernel) * signal。vDSP_zvmul 的共轭作用在第一个输入上。
                                vDSP_zvmul(&kernelSplit, 1, &signalSplit, 1, &productSplit, 1, vDSP_Length(fftLength), -1)
                                vDSP_fft_zip(setup, &productSplit, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
                            }
                        }
                    }
                }
            }
        }
        if let spectrumKey, !kernelIsSpectrum {
            kernelSpectra[spectrumKey] = (kernelReal, kernelImag)
        }

        var correlation = productReal
        var scale = 1 / Float(fftLength)
        vDSP_vsmul(correlation, 1, &scale, &correlation, 1, vDSP_Length(lags))

        var energy = [Float](repeating: 0, count: lags)
        var windowEnergy: Float = 0
        vDSP_svesq(Array(signal[0..<kernelCount]), 1, &windowEnergy, vDSP_Length(kernelCount))
        energy[0] = windowEnergy
        if lags > 1 {
            for lag in 1..<lags {
                let entering = signal[lag + kernelCount - 1]
                let leaving = signal[lag - 1]
                windowEnergy += entering * entering - leaving * leaving
                energy[lag] = windowEnergy
            }
        }

        var scores = [Float](repeating: 0, count: lags)
        for lag in 0..<lags {
            let sampleEnergy = energy[lag]
            guard sampleEnergy > 1e-12 else { continue }
            scores[lag] = correlation[lag] / sqrt(sampleEnergy * kernelEnergy)
        }
        return scores
    }

    /// 高于阈值的局部峰，按分数从高到低贪心保留，彼此至少相距 `minDistance`。
    static func preamblePeaks(scores: [Float], threshold: Float, minDistance: Int) -> [PreamblePeak] {
        guard !scores.isEmpty else { return [] }
        var candidates: [PreamblePeak] = []
        for index in scores.indices {
            let score = scores[index]
            guard score >= threshold else { continue }
            let notLowerThanLeft = index == 0 || score >= scores[index - 1]
            let higherThanRight = index == scores.count - 1 || score > scores[index + 1]
            if notLowerThanLeft && higherThanRight {
                candidates.append(PreamblePeak(index: index, score: score))
            }
        }
        candidates.sort { $0.score > $1.score }
        var kept: [PreamblePeak] = []
        for peak in candidates {
            if kept.allSatisfy({ abs($0.index - peak.index) >= minDistance }) {
                kept.append(peak)
            }
        }
        return kept
    }

    /// Matlab `find_symbol` 的 96 阶 FIR。只给同步用。
    /// 输出与输入等长。vDSP 卷积把对称 FIR 的峰提前 `syncFilterDelay` 点，调用方要把峰下标加回。
    static let syncFilterOrder = 96
    static let syncFilterDelay = syncFilterOrder / 2

    static func syncFilter(lowHz: Double, highHz: Double) -> [Float] {
        let fs = ScanProtocol.sampleRate
        let order = syncFilterOrder
        var taps = [Float](repeating: 0, count: order + 1)
        let mid = order / 2
        for index in 0...order {
            let offset = Double(index - mid)
            let ideal: Double
            if offset == 0 {
                ideal = 2 * (highHz - lowHz) / fs
            } else {
                ideal = (sin(2 * .pi * highHz * offset / fs) - sin(2 * .pi * lowHz * offset / fs)) / (.pi * offset)
            }
            let window = 0.54 - 0.46 * cos(2 * .pi * Double(index) / Double(order))
            taps[index] = Float(ideal * window)
        }
        return taps
    }

    static func bandpassForSync(_ samples: [Float], lowHz: Double, highHz: Double) -> [Float] {
        let taps = syncFilter(lowHz: lowHz, highHz: highHz)
        guard !samples.isEmpty, taps.count > 1 else { return samples }
        // vDSP_conv 读取 signal[n + p]，输入要比结果长 P-1。
        var padded = samples
        padded.append(contentsOf: repeatElement(0, count: taps.count - 1))
        var filtered = [Float](repeating: 0, count: samples.count)
        let reversed = Array(taps.reversed())
        padded.withUnsafeBufferPointer { source in
            reversed.withUnsafeBufferPointer { kernel in
                filtered.withUnsafeMutableBufferPointer { destination in
                    guard let signal = source.baseAddress,
                          let filter = kernel.baseAddress,
                          let output = destination.baseAddress else { return }
                    vDSP_conv(
                        signal, 1,
                        filter, 1,
                        output, 1,
                        vDSP_Length(samples.count),
                        vDSP_Length(taps.count)
                    )
                }
            }
        }
        return filtered
    }

    /// 原版 watercomms 对 1–4 kHz 前导用的 800–4000 Hz。实时集合用带频段参数的那个。
    static func bandpassForSync(_ samples: [Float]) -> [Float] {
        bandpassForSync(samples, lowHz: 800, highHz: 4_000)
    }

    /// watercomms `seekback`：在峰前 `seek` 点内，取第一个超过 `ratio * 峰` 的位置。
    static func seekback(scores: [Float], peak: Int, seek: Int = gap, ratio: Float = 0.4) -> Int {
        guard scores.indices.contains(peak) else { return max(0, peak) }
        let threshold = scores[peak] * ratio
        let start = max(0, peak - seek)
        for index in start...peak where scores[index] > threshold {
            return index
        }
        return peak
    }

    static func findPreambleStarts(in samples: [Float], set: SpectralSet, limit: Int = 8) -> [Int] {
        let kernel = preamble(for: set)
        let band = syncBand(for: set)
        let filtered = bandpassForSync(samples, lowHz: band.lowHz, highHz: band.highHz)
        let peaks = preamblePeaks(
            scores: preambleScores(in: filtered, kernel: kernel),
            threshold: 0.15,
            minDistance: 2_000
        )
        return peaks.prefix(limit).map { $0.index + syncFilterDelay }
    }

    static func findPreambleStart(in samples: [Float], set: SpectralSet) -> Int? {
        findPreambleStarts(in: samples, set: set, limit: 1).first
    }

    static func decode(frame: [Float], set: SpectralSet) -> UInt64? {
        decode(samples: frame, start: 0, set: set)
    }

    static func decode(samples: [Float], start: Int, set: SpectralSet) -> UInt64? {
        let dataStart = start + preamble(for: set).count + gap
        guard dataStart >= 0, dataStart < samples.count else { return nil }
        let plan = plan(for: set)
        guard let demod = OFDMModem.demodulateFrequencyOnly(window: samples, symbolStart: dataStart, plan: plan) else { return nil }
        let decoded = ConvolutionalCode.decode(demod.bits)
        guard decoded.count == PacketLayout.bitCount else { return nil }
        var word: UInt64 = 0
        for bit in decoded { word = (word << 1) | (bit ? 1 : 0) }
        guard ScanPayload.setCode(of: word) == set.code else { return nil }
        return word
    }
}
