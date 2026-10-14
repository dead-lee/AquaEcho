import Foundation

/// 在连续录音里按发送顺序寻找每个包，并用 Goertzel 测量两个目标频率。
/// ggwave 的解码由调用方注入，这样评分核心不依赖 C 库。
enum SignalAnalyzer {
    typealias GGWaveMatcher = (_ samples: [Float], _ sampleRate: Double, _ packet: SentPacket) -> Bool

    struct Result {
        var transmissions: [Transmission]
        var pairs: [PairScore]
    }

    static func analyze(
        capture: CaptureBuffer,
        packets: [SentPacket],
        config: TestConfig,
        mode: TestMode,
        ggwaveMatches: GGWaveMatcher? = nil
    ) -> Result {
        let settings = config.normalized
        let ordered = packets.sorted { $0.sequence < $1.sequence }
        let sampleRate = capture.sampleRate
        let silenceSamples = Int(((settings.leadSilenceMs + settings.trailSilenceMs) / 1_000) * sampleRate)
        let signalSamples = max(Int(0.2 * sampleRate), Int(settings.expectedSignalSeconds * sampleRate))
        let window = analysisWindow(config: settings, sampleRate: sampleRate)
        var cursor = 0
        var transmissions: [Transmission] = []

        for (index, packet) in ordered.enumerated() {
            let slack = index == 0 ? Int(2.0 * sampleRate) : Int(0.8 * sampleRate)
            let searchEnd = min(capture.samples.count, cursor + signalSamples + silenceSamples + slack)
            if cursor >= searchEnd {
                transmissions.append(missed(packet))
                continue
            }
            let region = Array(capture.samples[cursor..<searchEnd])
            let fit = bestBurst(
                region: region,
                sampleRate: sampleRate,
                f0: packet.lowHz,
                f1: packet.highHz,
                signalSamples: signalSamples,
                window: window
            )
            let absoluteStart = cursor + fit.start
            var transmission = Transmission(
                packet: packet,
                phoneReceiveDate: capture.date(forSample: absoluteStart),
                packetSNRdB: fit.snrDB,
                packetRatioDB: fit.ratioDB,
                packetPower: fit.power,
                detected: fit.snrDB >= 5,
                ggwaveDecoded: nil
            )
            if mode == .ggwave, let ggwaveMatches {
                let padding = Int(0.2 * sampleRate)
                let decodeStart = max(0, absoluteStart - padding)
                let decodeEnd = min(capture.samples.count, absoluteStart + signalSamples + padding)
                let slice = Array(capture.samples[decodeStart..<decodeEnd])
                transmission.ggwaveDecoded = ggwaveMatches(slice, sampleRate, packet)
            }
            transmissions.append(transmission)
            let step = signalSamples + silenceSamples / 2
            if fit.snrDB >= 5 {
                cursor = min(capture.samples.count, absoluteStart + step)
            } else {
                cursor = min(capture.samples.count, cursor + step)
            }
        }

        return Result(transmissions: transmissions, pairs: aggregate(transmissions, mode: mode))
    }

    private static func analysisWindow(config: TestConfig, sampleRate: Double) -> Int {
        switch config.mode {
        case .cpfsk:
            return max(256, Int((config.symbolDurationMs / 1_000) * sampleRate))
        case .ggwave:
            return max(256, Int(1_024 * sampleRate / GGWaveBand.sampleRate))
        }
    }

    private static func missed(_ packet: SentPacket) -> Transmission {
        Transmission(
            packet: packet,
            phoneReceiveDate: nil,
            packetSNRdB: 0,
            packetRatioDB: 0,
            packetPower: 0,
            detected: false,
            ggwaveDecoded: false
        )
    }

    private struct WindowReading {
        var snrDB: Double
        var ratioDB: Double
        var signalPower: Double
    }

    private struct BurstFit {
        var start: Int
        var snrDB: Double
        var ratioDB: Double
        var power: Double
    }

    private static func bestBurst(
        region: [Float],
        sampleRate: Double,
        f0: Double,
        f1: Double,
        signalSamples: Int,
        window: Int
    ) -> BurstFit {
        guard region.count >= window else {
            let reading = measureWindow(
                samples: region[region.startIndex..<region.endIndex],
                sampleRate: sampleRate,
                f0: f0,
                f1: f1
            )
            return BurstFit(start: 0, snrDB: reading.snrDB, ratioDB: reading.ratioDB, power: reading.signalPower)
        }

        let hop = max(128, window / 2)
        let noise = Goertzel.noiseFrequencies(f0: f0, f1: f1, sampleRate: sampleRate)
        var starts: [Int] = []
        var readings: [WindowReading] = []
        var offset = 0
        while offset + window <= region.count {
            let slice = region[offset..<(offset + window)]
            readings.append(measureWindow(samples: slice, sampleRate: sampleRate, f0: f0, f1: f1, noiseFrequencies: noise))
            starts.append(offset)
            offset += hop
        }
        guard let firstStart = starts.first else {
            return BurstFit(start: 0, snrDB: -10, ratioDB: 0, power: 0)
        }

        let span = max(1, signalSamples / hop)
        if readings.count <= span {
            let combined = combine(readings)
            return BurstFit(start: firstStart, snrDB: combined.snrDB, ratioDB: combined.ratioDB, power: combined.signalPower)
        }

        var bestIndex = 0
        var bestAverage = -Double.infinity
        var running = readings[0..<span].reduce(0.0) { $0 + $1.snrDB }
        bestAverage = running / Double(span)
        if readings.count > span {
            for index in 1...(readings.count - span) {
                running += readings[index + span - 1].snrDB - readings[index - 1].snrDB
                let average = running / Double(span)
                if average > bestAverage {
                    bestAverage = average
                    bestIndex = index
                }
            }
        }
        let chosen = Array(readings[bestIndex..<(bestIndex + span)])
        let combined = combine(chosen)
        return BurstFit(
            start: starts[bestIndex],
            snrDB: combined.snrDB,
            ratioDB: combined.ratioDB,
            power: combined.signalPower
        )
    }

    private static func measureWindow(
        samples: ArraySlice<Float>,
        sampleRate: Double,
        f0: Double,
        f1: Double,
        noiseFrequencies: [Double]? = nil
    ) -> WindowReading {
        let p0 = Goertzel.power(samples: samples, sampleRate: sampleRate, frequency: f0)
        let p1 = Goertzel.power(samples: samples, sampleRate: sampleRate, frequency: f1)
        let noiseBins = noiseFrequencies ?? Goertzel.noiseFrequencies(f0: f0, f1: f1, sampleRate: sampleRate)
        let noisePower = noiseBins.reduce(0.0) { partial, frequency in
            partial + Goertzel.power(samples: samples, sampleRate: sampleRate, frequency: frequency)
        } / Double(noiseBins.count)
        let signal = max(p0, p1)
        let inactive = max(min(p0, p1), 1e-20)
        let noise = max(noisePower, 1e-20)
        let snr = (10 * log10(max(signal, 1e-20) / noise)).clamped(to: -10...80)
        let ratio = (10 * log10(max(signal, 1e-20) / inactive)).clamped(to: 0...60)
        return WindowReading(snrDB: snr, ratioDB: ratio, signalPower: signal)
    }

    /// 只把明显高于噪声的窗计入 SNR 和区分度，避免前后静音把分数拉低。
    private static func combine(_ windows: [WindowReading]) -> WindowReading {
        guard !windows.isEmpty else {
            return WindowReading(snrDB: -10, ratioDB: 0, signalPower: 0)
        }
        let active = windows.filter { $0.snrDB >= 6 }
        let used = active.isEmpty ? [windows.max { $0.snrDB < $1.snrDB }!] : active
        return WindowReading(
            snrDB: mean(used.map(\.snrDB)),
            ratioDB: mean(used.map(\.ratioDB)),
            signalPower: mean(used.map(\.signalPower))
        )
    }

    private static func aggregate(_ transmissions: [Transmission], mode: TestMode) -> [PairScore] {
        let groups = Dictionary(grouping: transmissions) { transmission in
            PairKey(low: (transmission.packet.lowHz * 100).rounded(), high: (transmission.packet.highHz * 100).rounded())
        }
        let scores = groups.values.map { items -> PairScore in
            let ordered = items.sorted { $0.packet.sequence < $1.packet.sequence }
            let first = ordered[0].packet
            let powers = ordered.map(\.packetPower)
            let cv = ChannelScore.coefficientOfVariation(powers)
            let snr = mean(ordered.map(\.packetSNRdB))
            let ratio = mean(ordered.map(\.packetRatioDB))
            let decodeRate: Double?
            if mode == .ggwave {
                let hits = ordered.filter { $0.ggwaveDecoded == true }.count
                decodeRate = Double(hits) / Double(ordered.count)
            } else {
                decodeRate = nil
            }
            return PairScore(
                mode: mode,
                lowHz: first.lowHz,
                highHz: first.highHz,
                meanSNRdB: snr,
                stabilityCV: cv,
                ratioDB: ratio,
                decodeRate: decodeRate,
                score: ChannelScore.breakdown(
                    mode: mode,
                    snrDB: snr,
                    coefficientOfVariation: cv,
                    ratioDB: ratio,
                    decodeRate: decodeRate
                ),
                transmissions: ordered
            )
        }
        return scores.sorted { lhs, rhs in
            if lhs.score.total == rhs.score.total {
                return lhs.meanSNRdB > rhs.meanSNRdB
            }
            return lhs.score.total > rhs.score.total
        }
    }

    private struct PairKey: Hashable {
        var low: Double
        var high: Double
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
