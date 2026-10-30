import Foundation
import Accelerate

/// watercomms 对齐版 PHY：Naiser3 前导 + 960 gap + 训练/数据符号，Ns=960、Cp=67。
enum WatercommsPhy {
    static let ns = 960
    static let cp = 67
    static let gap = 960
    static var preamble: [Float] { WatercommsPreamble.samples }

    static func plan(for set: SpectralSet) -> OFDMModem.Plan {
        OFDMModem.plan(
            carriers: set.carriers,
            sampleRate: ScanProtocol.sampleRate,
            ns: ns,
            cp: cp,
            preamble: preamble,
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

    /// 归一化互相关。lag 处的值是前导与 `signal[lag..<lag+P]` 的相关系数。
    static func preambleScores(in signal: [Float]) -> [Float] {
        let kernel = preamble
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
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var signalReal = [Float](repeating: 0, count: fftLength)
        var signalImag = [Float](repeating: 0, count: fftLength)
        var kernelReal = [Float](repeating: 0, count: fftLength)
        var kernelImag = [Float](repeating: 0, count: fftLength)
        signalReal.replaceSubrange(0..<sampleCount, with: signal)
        kernelReal.replaceSubrange(0..<kernelCount, with: kernel)

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
                                vDSP_fft_zip(setup, &kernelSplit, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                                // conj(kernel) * signal。vDSP_zvmul 的共轭作用在第一个输入上。
                                vDSP_zvmul(&kernelSplit, 1, &signalSplit, 1, &productSplit, 1, vDSP_Length(fftLength), -1)
                                vDSP_fft_zip(setup, &productSplit, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
                            }
                        }
                    }
                }
            }
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

    /// Matlab `find_symbol` 在 seekback 之后把窗口起点前移 300 点，
    /// `channe_look_back` 取 1–4 kHz 信道冲激里噪声门限以上的最早径。
    static let channelLookbackLead = 300

    static func channelLookbackStart(samples: [Float], seekbackLag: Int) -> Int {
        let count = preamble.count
        let lead = channelLookbackLead
        let windowStart = seekbackLag - lead
        guard windowStart >= 0, windowStart + count <= samples.count else { return seekbackLag }
        let segment = Array(samples[windowStart..<(windowStart + count)])
        guard let delay = earliestPreamblePath(segment: segment) else { return seekbackLag }
        let start = windowStart + delay
        guard start >= 0, start < samples.count else { return seekbackLag }
        return start
    }

    private static func earliestPreamblePath(segment: [Float]) -> Int? {
        let fftLength = 16_384
        let log2n = 14
        guard segment.count == preamble.count,
              let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var receivedReal = [Float](repeating: 0, count: fftLength)
        var receivedImag = [Float](repeating: 0, count: fftLength)
        var preambleReal = [Float](repeating: 0, count: fftLength)
        var preambleImag = [Float](repeating: 0, count: fftLength)
        receivedReal.replaceSubrange(0..<segment.count, with: segment)
        preambleReal.replaceSubrange(0..<preamble.count, with: preamble)

        receivedReal.withUnsafeMutableBufferPointer { receivedRealBuffer in
            receivedImag.withUnsafeMutableBufferPointer { receivedImagBuffer in
                preambleReal.withUnsafeMutableBufferPointer { preambleRealBuffer in
                    preambleImag.withUnsafeMutableBufferPointer { preambleImagBuffer in
                        var received = DSPSplitComplex(realp: receivedRealBuffer.baseAddress!, imagp: receivedImagBuffer.baseAddress!)
                        var transmitted = DSPSplitComplex(realp: preambleRealBuffer.baseAddress!, imagp: preambleImagBuffer.baseAddress!)
                        vDSP_fft_zip(setup, &received, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                        vDSP_fft_zip(setup, &transmitted, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                    }
                }
            }
        }

        let lowBin = Int((1_000 * Double(fftLength) / ScanProtocol.sampleRate).rounded())
        let highBin = Int((4_000 * Double(fftLength) / ScanProtocol.sampleRate).rounded())
        var responseReal = [Float](repeating: 0, count: fftLength)
        var responseImag = [Float](repeating: 0, count: fftLength)
        if lowBin >= 1, highBin < fftLength / 2 {
            for bin in lowBin...highBin {
                let xre = preambleReal[bin]
                let xim = preambleImag[bin]
                let power = xre * xre + xim * xim
                guard power > 1e-12 else { continue }
                let yre = receivedReal[bin]
                let yim = receivedImag[bin]
                responseReal[bin] = (yre * xre + yim * xim) / power
                responseImag[bin] = (yim * xre - yre * xim) / power
            }
        }

        responseReal.withUnsafeMutableBufferPointer { realBuffer in
            responseImag.withUnsafeMutableBufferPointer { imagBuffer in
                var response = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                vDSP_fft_zip(setup, &response, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
            }
        }

        var magnitude = [Double](repeating: 0, count: fftLength)
        var peakValue = 0.0
        for index in 0..<fftLength {
            let value = hypot(Double(responseReal[index]), Double(responseImag[index]))
            magnitude[index] = value
            peakValue = max(peakValue, value)
        }
        guard peakValue > 0 else { return nil }
        for index in 0..<fftLength { magnitude[index] /= peakValue }

        let tailCount = 500
        let noise = magnitude.suffix(tailCount).reduce(0, +) / Double(tailCount) * 1.5 + 0.15
        guard let path = magnitude.enumerated().max(by: { $0.element < $1.element })?.offset else { return nil }
        let limit = min(fftLength - 2, path + 10)
        guard limit >= 1 else { return path }
        var peaks: [Int] = []
        var index = 1
        while index <= limit {
            let value = magnitude[index]
            if value >= noise, value >= magnitude[index - 1], value >= magnitude[index + 1] {
                if let last = peaks.last, index - last < 5 {
                    if value > magnitude[last] { peaks[peaks.count - 1] = index }
                } else {
                    peaks.append(index)
                }
                index += 5
            } else {
                index += 1
            }
        }
        return peaks.first ?? path
    }

    static func findPreambleStarts(in samples: [Float], limit: Int = 8) -> [Int] {
        let peaks = preamblePeaks(
            scores: preambleScores(in: samples),
            threshold: 0.15,
            minDistance: 2_000
        )
        return peaks.prefix(limit).map(\.index)
    }

    static func findPreambleStart(in samples: [Float]) -> Int? {
        findPreambleStarts(in: samples, limit: 1).first
    }

    static func decode(frame: [Float], set: SpectralSet) -> UInt64? {
        decode(samples: frame, start: 0, set: set)
    }

    static func decode(samples: [Float], start: Int, set: SpectralSet) -> UInt64? {
        let dataStart = start + preamble.count + gap
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
