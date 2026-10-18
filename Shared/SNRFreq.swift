import Foundation

/// watercomms `SNR_freq.calculate_snr`：每个 OFDM bin 的信号功率除以噪声方差，再换成 dB。
enum SNRFreq {
    /// `rxReal[bin][symbol]` 对应 Java 的 `rx_spectrum[0][i][j]`。`mag2db` 是 20·log10，结果再除以 2。
    static func calculateSNR(
        rxReal: [[Double]],
        rxImag: [[Double]],
        groundTruth: [Double],
        symbolStart: Int,
        symbolEnd: Int
    ) -> [Double] {
        let binCount = groundTruth.count
        let symbolCount = symbolEnd - symbolStart
        guard symbolCount > 0, rxReal.count == binCount, rxImag.count == binCount else {
            return Array(repeating: -.infinity, count: max(0, binCount))
        }
        var snr = [Double](repeating: -.infinity, count: binCount)
        for bin in 0..<binCount {
            guard rxReal[bin].count >= symbolEnd, rxImag[bin].count >= symbolEnd else { continue }
            let sign = groundTruth[bin]
            var meanReal = 0.0
            var meanImag = 0.0
            for symbol in symbolStart..<symbolEnd {
                meanReal += rxReal[bin][symbol] * sign
                meanImag += rxImag[bin][symbol] * sign
            }
            meanReal /= Double(symbolCount)
            meanImag /= Double(symbolCount)
            var noise = 0.0
            for symbol in symbolStart..<symbolEnd {
                let real = rxReal[bin][symbol] * sign - meanReal
                let imag = meanImag - rxImag[bin][symbol] * sign
                noise += real * real + imag * imag
            }
            noise /= Double(symbolCount)
            let signal = meanReal * meanReal + meanImag * meanImag
            if noise <= 0 {
                snr[bin] = signal > 0 ? .infinity : -.infinity
            } else if signal <= 0 {
                snr[bin] = -.infinity
            } else {
                snr[bin] = 20 * log10(signal / noise) / 2
            }
        }
        return snr
    }

    /// 超过阈值的最长连续区间。同样长时保留频率更低的那一段。
    static func longestInterval(_ snr: [Double], thresholdDB: Double = OFDMConstants.snrSelectThresholdDb) -> ClosedRange<Int>? {
        let count = snr.count
        guard count > 0 else { return nil }
        for length in stride(from: count, through: 1, by: -1) {
            for start in 0...(count - length) {
                let end = start + length - 1
                var passes = true
                for index in start...end where !(snr[index] > thresholdDB) {
                    passes = false
                    break
                }
                if passes {
                    return start...end
                }
            }
        }
        return nil
    }

    /// 前导里 8 段相同的 Naiser 片段对齐后，按候选范围里的 OFDM bin 选频。
    /// 返回值可以直接传给 `OFDMModem.plan(f0:f1:)`：`fend` 是最后一个入选 bin 的上沿。
    static func selectedBand(
        samples: [Float],
        arrival: Int,
        sampleRate: Double,
        frequency: FrequencyConfig
    ) -> (fbegin: Double, fend: Double)? {
        let ns = OFDMConstants.naiserNu
        let gap = OFDMConstants.naiserN0
        let symbols = OFDMModem.naiserPN.count
        let preambleCount = symbols * ns + (symbols - 1) * gap
        guard arrival >= 0, sampleRate > 0, arrival + preambleCount <= samples.count else { return nil }
        let spacing = sampleRate / Double(ns)
        var lowBin = Int((frequency.candidateLowHz / spacing).rounded())
        var highBin = Int((frequency.candidateHighHz / spacing).rounded()) - 1
        let nyquist = ns / 2 - 1
        lowBin = min(max(lowBin, 1), nyquist)
        highBin = min(max(highBin, lowBin), nyquist)
        let binCount = highBin - lowBin + 1
        guard binCount > 0 else { return nil }
        var rxReal = Array(repeating: Array(repeating: 0.0, count: symbols), count: binCount)
        var rxImag = Array(repeating: Array(repeating: 0.0, count: symbols), count: binCount)
        for symbol in 0..<symbols {
            let start = arrival + symbol * (ns + gap)
            var segment = Array(samples[start..<(start + ns)])
            if OFDMModem.naiserPN[symbol] < 0 {
                for index in segment.indices {
                    segment[index] = -segment[index]
                }
            }
            let spectrum = OFDMModem.spectrum(segment)
            guard spectrum.real.count == ns else { return nil }
            for offset in 0..<binCount {
                let bin = lowBin + offset
                rxReal[offset][symbol] = Double(spectrum.real[bin])
                rxImag[offset][symbol] = Double(spectrum.imag[bin])
            }
        }
        let groundTruth = Array(repeating: 1.0, count: binCount)
        let snr = calculateSNR(
            rxReal: rxReal,
            rxImag: rxImag,
            groundTruth: groundTruth,
            symbolStart: 0,
            symbolEnd: symbols
        )
        guard let range = longestInterval(snr) else { return nil }
        let first = lowBin + range.lowerBound
        let last = lowBin + range.upperBound
        return (Double(first) * spacing, Double(last + 1) * spacing)
    }
}
