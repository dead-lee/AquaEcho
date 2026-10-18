import Foundation

/// watercomms `FeedbackSignal`：两个单频正弦把选中区间的起止频率送回发送端。
enum FeedbackSignal {
    /// `Constants.fbackTime`，毫秒。
    static let feedbackMilliseconds = 200
    /// `Constants.ChirpGap`。
    static let chirpGap = 960
    /// `Constants.FEEDBACK_SNR_THRESH`。反馈峰和邻域噪声的 dB 差。
    static let feedbackSNRThresholdDB = 13.0

    /// 只含现有 Naiser 前导，前后沿用配置里的静音，不带数据符号。
    static func soundingSignal(config: TestConfig) -> (samples: [Float], leadSamples: Int) {
        let config = config.normalized
        let lead = max(0, Int((config.leadSilenceMs / 1_000 * config.sampleRate).rounded()))
        let trail = max(0, Int((config.trailSilenceMs / 1_000 * config.sampleRate).rounded()))
        let preamble = NaiserWaveform.samples
        var output = [Float](repeating: 0, count: lead + preamble.count + trail)
        output.replaceSubrange(lead..<(lead + preamble.count), with: preamble)
        return (output, lead)
    }

    /// `encodeFeedbackSignal`。`fbegin`、`fend` 是频率，正弦相位用整段信号的采样下标。
    static func encodeFeedbackSignal(fbegin: Double, fend: Double, sampleRate: Double) -> [Float] {
        let preamble = NaiserWaveform.samples
        let bodyCount = max(1, Int((Double(feedbackMilliseconds) / 1_000 * sampleRate).rounded()))
        var signal = [Float](repeating: 0, count: preamble.count + chirpGap + bodyCount)
        signal.replaceSubrange(0..<preamble.count, with: preamble)
        let bodyStart = preamble.count + chirpGap
        let lows = (fbegin / 10).rounded() * 10
        let highs = (fend / 10).rounded() * 10
        let amplitude = OFDMModem.playbackAmplitude / 2
        for frequency in [lows, highs] {
            for index in bodyStart..<signal.count {
                let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
                signal[index] += Float(sin(phase)) * amplitude
            }
        }
        return signal
    }

    static func playback(fbegin: Double, fend: Double, config: TestConfig) -> [Float] {
        let config = config.normalized
        let tone = encodeFeedbackSignal(fbegin: fbegin, fend: fend, sampleRate: config.sampleRate)
        let lead = max(0, Int((config.leadSilenceMs / 1_000 * config.sampleRate).rounded()))
        let trail = max(0, Int((config.trailSilenceMs / 1_000 * config.sampleRate).rounded()))
        var output = [Float](repeating: 0, count: lead + tone.count + trail)
        output.replaceSubrange(lead..<(lead + tone.count), with: tone)
        return output
    }

    /// 在录音里找反馈前导，解析两个正弦，再按 `fs/Ns` 把频率收到子载波网格上。
    static func frequencies(
        in samples: [Float],
        sampleRate: Double,
        frequency: FrequencyConfig
    ) -> (fbegin: Double, fend: Double)? {
        let rate = 48_000.0
        let audio = resample(samples, from: sampleRate, to: rate)
        let low = frequency.candidateLowHz
        let high = frequency.candidateHighHz
        let filtered = OFDMModem.bandpass(audio, lowHz: low, highHz: high, sampleRate: rate)
        let preamble = NaiserWaveform.samples
        guard filtered.count > preamble.count else { return nil }
        var correlation = OFDMModem.correlate(signal: filtered, template: preamble)
        let bodyCount = max(1, Int((Double(feedbackMilliseconds) / 1_000 * rate).rounded()))
        for _ in 0..<4 {
            var best = Float(0)
            var bestAt = -1
            for index in correlation.indices where correlation[index] > best {
                best = correlation[index]
                bestAt = index
            }
            guard bestAt >= 0, best > 0 else { return nil }
            if OFDMModem.naiserLock(samples: filtered, peakIndex: bestAt) != nil {
                let arrival = OFDMModem.earliestArrival(
                    filtered: filtered,
                    correlation: correlation,
                    peakIndex: bestAt,
                    preamble: preamble,
                    sampleRate: rate,
                    lowHz: low,
                    highHz: high
                )
                let bodyStart = arrival + preamble.count + chirpGap
                let bodyEnd = bodyStart + bodyCount
                if bodyStart >= 0, bodyEnd <= audio.count,
                   let decoded = decodeFeedbackSignal(
                    Array(audio[bodyStart..<bodyEnd]),
                    sampleRate: rate,
                    frequency: frequency
                   ) {
                    return snap(decoded, sampleRate: rate)
                }
            }
            let from = max(0, bestAt - 2_400)
            let to = min(correlation.count, bestAt + 2_400)
            for index in from..<to {
                correlation[index] = 0
            }
        }
        return nil
    }

    /// `decodeFeedbackSignal`。返回两个峰的频率；只有一个峰时起止相同。
    static func decodeFeedbackSignal(
        _ samples: [Float],
        sampleRate: Double,
        frequency: FrequencyConfig
    ) -> (fbegin: Double, fend: Double)? {
        let magnitude = OFDMModem.magnitudeSpectrum(samples)
        guard !magnitude.isEmpty else { return nil }
        let decibels = magnitude.map(mag2db)
        let spacing = max(1, Int(sampleRate) / decibels.count)
        let startIndex = max(0, Int(frequency.candidateLowHz) / spacing)
        let endIndex = min(decibels.count - 1, Int(frequency.candidateHighHz) / spacing)
        guard startIndex <= endIndex else { return nil }
        var bins: [Peak] = []
        for index in startIndex...endIndex {
            guard index - 5 >= 0, index + 5 < decibels.count else { continue }
            let signal = decibels[index]
            let noiseBins = Array(decibels[(index - 5)...(index - 2)]) + Array(decibels[(index + 2)...(index + 5)])
            let noise = noiseBins.reduce(0, +) / Double(noiseBins.count)
            let snr = signal - noise
            let prominence = prominence(decibels, peak: index, begin: index - 2, end: index + 2)
            if snr >= feedbackSNRThresholdDB {
                bins.append(Peak(freq: index * spacing, snr: snr, prominence: prominence))
            }
        }
        bins.sort { ($0.prominence + $0.snr) < ($1.prominence + $1.snr) }
        var remove = Set<Int>()
        if bins.count >= 2 {
            for index in stride(from: bins.count - 1, through: 1, by: -1) {
                if abs(bins[index].freq - bins[index - 1].freq) == spacing {
                    if bins[index].snr > bins[index - 1].snr {
                        remove.insert(index)
                    } else {
                        remove.insert(index - 1)
                    }
                }
            }
        }
        for index in remove.sorted(by: >) {
            bins.remove(at: index)
        }
        guard !bins.isEmpty else { return nil }
        if bins.count == 1 {
            let freq = Double(bins[0].freq)
            return (freq, freq)
        }
        var first = bins[bins.count - 1]
        var second = bins[bins.count - 2]
        if let lower = bins.first(where: { $0.freq == first.freq / 2 }), lower.snr > first.snr {
            first = lower
        }
        if let lower = bins.first(where: { $0.freq == second.freq / 2 }), lower.snr > second.snr {
            second = lower
        }
        guard first.snr >= feedbackSNRThresholdDB, second.snr >= feedbackSNRThresholdDB else { return nil }
        let low = Double(min(first.freq, second.freq))
        let high = Double(max(first.freq, second.freq))
        return (low, high)
    }

    private struct Peak {
        var freq: Int
        var snr: Double
        var prominence: Double
    }

    /// `getProm`。比较窗口是峰两侧各 2 个 bin。
    private static func prominence(_ values: [Double], peak: Int, begin: Int, end: Int) -> Double {
        guard values.indices.contains(peak), values.indices.contains(begin), values.indices.contains(end) else { return 0 }
        let peakValue = values[peak]
        var leftMarker = 0
        var rightMarker = end
        if peak > begin {
            for index in stride(from: peak - 1, through: begin, by: -1) {
                if values[index] >= peakValue {
                    leftMarker = index
                    break
                }
            }
        }
        if peak + 1 < end {
            for index in (peak + 1)..<end where values[index] >= peakValue {
                rightMarker = index
                break
            }
        }
        var leftMinimum = values[begin]
        var rightMinimum = values[end]
        if begin < leftMarker {
            for index in begin..<leftMarker where values[index] < leftMinimum {
                leftMinimum = values[index]
            }
        }
        if rightMarker < end {
            for index in rightMarker..<end where values[index] < rightMinimum {
                rightMinimum = values[index]
            }
        }
        let reference = max(leftMinimum, rightMinimum)
        return peakValue - reference
    }

    private static func mag2db(_ magnitude: Double) -> Double {
        guard magnitude > 0 else { return -300 }
        return 20 * log10(magnitude)
    }

    /// `extractSignalHelper` 把解析结果收到 `fs/Ns` 的网格上。
    private static func snap(_ band: (fbegin: Double, fend: Double), sampleRate: Double) -> (fbegin: Double, fend: Double)? {
        let inc = Double(max(1, Int(sampleRate) / OFDMModem.naiserNu))
        let fbegin = ceil(band.fbegin / inc) * inc
        let fend = floor(band.fend / inc) * inc
        guard fend >= fbegin else { return nil }
        return (fbegin, fend)
    }

    private static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        guard inputRate > 0, outputRate > 0, !samples.isEmpty else { return samples }
        if abs(inputRate - outputRate) < 1 { return samples }
        let count = Int((Double(samples.count) * outputRate / inputRate).rounded(.down))
        guard count > 1 else { return samples }
        var output = [Float](repeating: 0, count: count)
        let scale = inputRate / outputRate
        for index in 0..<count {
            let position = Double(index) * scale
            let lower = Int(position)
            let upper = min(samples.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            output[index] = samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
        return output
    }
}
