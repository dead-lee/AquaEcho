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
                detected: fit.snrDB >= 5,
                ggwaveDecoded: nil,
                passed: false
            )
            if mode == .cpfsk {
                let decoded = demodulatedPayload(
                    samples: capture.samples,
                    sampleRate: sampleRate,
                    burstStart: absoluteStart,
                    f0: packet.lowHz,
                    f1: packet.highHz,
                    symbolSeconds: settings.symbolDurationMs / 1_000
                )
                transmission.passed = decoded != nil && decoded == PacketFactory.data(hex: packet.payloadHex)
            } else if mode == .ggwave, let ggwaveMatches {
                let padding = Int(0.2 * sampleRate)
                let decodeStart = max(0, absoluteStart - padding)
                let decodeEnd = min(capture.samples.count, absoluteStart + signalSamples + padding)
                let slice = Array(capture.samples[decodeStart..<decodeEnd])
                let matched = ggwaveMatches(slice, sampleRate, packet)
                transmission.ggwaveDecoded = matched
                transmission.passed = matched
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
            detected: false,
            ggwaveDecoded: false,
            passed: false
        )
    }

    private struct WindowReading {
        var snrDB: Double
        var ratioDB: Double
    }

    private struct BurstFit {
        var start: Int
        var snrDB: Double
        var ratioDB: Double
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
            return BurstFit(start: 0, snrDB: reading.snrDB, ratioDB: reading.ratioDB)
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
            return BurstFit(start: 0, snrDB: -10, ratioDB: 0)
        }

        let span = max(1, signalSamples / hop)
        if readings.count <= span {
            let combined = combine(readings)
            return BurstFit(start: firstStart, snrDB: combined.snrDB, ratioDB: combined.ratioDB)
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
            ratioDB: combined.ratioDB
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
        return WindowReading(snrDB: snr, ratioDB: ratio)
    }

    /// 只把明显高于噪声的窗计入 SNR 和区分度，避免前后静音把分数拉低。
    private static func combine(_ windows: [WindowReading]) -> WindowReading {
        guard !windows.isEmpty else {
            return WindowReading(snrDB: -10, ratioDB: 0)
        }
        let active = windows.filter { $0.snrDB >= 6 }
        let used = active.isEmpty ? [windows.max { $0.snrDB < $1.snrDB }!] : active
        return WindowReading(
            snrDB: mean(used.map(\.snrDB)),
            ratioDB: mean(used.map(\.ratioDB))
        )
    }

    /// 在检出的突发附近滑动符号网格，用 0xAA 0x55 对齐，再按两个目标频率的能量逐符号还原 8 字节。
    private static func demodulatedPayload(
        samples: [Float],
        sampleRate: Double,
        burstStart: Int,
        f0: Double,
        f1: Double,
        symbolSeconds: Double
    ) -> Data? {
        let symbolSamples = max(1, Int((symbolSeconds * sampleRate).rounded()))
        let preamble = preambleBits()
        let totalBits = preamble.count + PacketLayout.payloadBytes * 8
        let frameSamples = symbolSamples * totalBits
        guard frameSamples > 0, samples.count >= frameSamples else { return nil }

        let search = max(symbolSamples, Int(0.12 * sampleRate))
        let coarse = max(1, symbolSamples / 8)
        guard let coarseBest = bestAlignment(
            samples: samples,
            sampleRate: sampleRate,
            center: burstStart,
            radius: search,
            step: coarse,
            symbolSamples: symbolSamples,
            preamble: preamble,
            f0: f0,
            f1: f1
        ) else { return nil }
        let aligned = bestAlignment(
            samples: samples,
            sampleRate: sampleRate,
            center: coarseBest.offset,
            radius: coarse,
            step: 1,
            symbolSamples: symbolSamples,
            preamble: preamble,
            f0: f0,
            f1: f1
        ) ?? coarseBest
        guard aligned.hits == preamble.count,
              aligned.offset >= 0,
              aligned.offset + frameSamples <= samples.count else { return nil }

        let bits = symbolBits(
            samples: samples,
            sampleRate: sampleRate,
            offset: aligned.offset,
            count: totalBits,
            symbolSamples: symbolSamples,
            f0: f0,
            f1: f1
        )
        let bytes = bytesFromBits(bits)
        let preambleCount = PacketLayout.preamble.count
        guard bytes.count == preambleCount + PacketLayout.payloadBytes,
              Array(bytes.prefix(preambleCount)) == PacketLayout.preamble else { return nil }
        return Data(bytes.dropFirst(preambleCount))
    }

    private struct Alignment {
        var offset: Int
        var hits: Int
        var margin: Double
    }

    private static func bestAlignment(
        samples: [Float],
        sampleRate: Double,
        center: Int,
        radius: Int,
        step: Int,
        symbolSamples: Int,
        preamble: [Bool],
        f0: Double,
        f1: Double
    ) -> Alignment? {
        let preambleSamples = preamble.count * symbolSamples
        var best: Alignment?
        var offset = center - radius
        let last = center + radius
        let stride = max(1, step)
        while offset <= last {
            if offset >= 0, offset + preambleSamples <= samples.count {
                var hits = 0
                var margin = 0.0
                for (index, expected) in preamble.enumerated() {
                    let start = offset + index * symbolSamples
                    let end = start + symbolSamples
                    let decision = bitDecision(
                        samples: samples[start..<end],
                        sampleRate: sampleRate,
                        f0: f0,
                        f1: f1
                    )
                    if decision.one == expected {
                        hits += 1
                    }
                    margin += decision.margin
                }
                if best == nil || hits > best!.hits || (hits == best!.hits && margin > best!.margin) {
                    best = Alignment(offset: offset, hits: hits, margin: margin)
                }
            }
            offset += stride
        }
        return best
    }

    private static func symbolBits(
        samples: [Float],
        sampleRate: Double,
        offset: Int,
        count: Int,
        symbolSamples: Int,
        f0: Double,
        f1: Double
    ) -> [Bool] {
        var bits: [Bool] = []
        bits.reserveCapacity(count)
        for index in 0..<count {
            let start = offset + index * symbolSamples
            let end = start + symbolSamples
            bits.append(bitDecision(samples: samples[start..<end], sampleRate: sampleRate, f0: f0, f1: f1).one)
        }
        return bits
    }

    private static func bitDecision(
        samples: ArraySlice<Float>,
        sampleRate: Double,
        f0: Double,
        f1: Double
    ) -> (one: Bool, margin: Double) {
        let low = Goertzel.power(samples: samples, sampleRate: sampleRate, frequency: f0)
        let high = Goertzel.power(samples: samples, sampleRate: sampleRate, frequency: f1)
        return (high > low, abs(high - low))
    }

    private static func preambleBits() -> [Bool] {
        var bits: [Bool] = []
        for byte in PacketLayout.preamble {
            for shift in stride(from: 7, through: 0, by: -1) {
                bits.append(((byte >> shift) & 0x01) == 1)
            }
        }
        return bits
    }

    private static func bytesFromBits(_ bits: [Bool]) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = 0
        while index + 8 <= bits.count {
            var byte: UInt8 = 0
            for shift in 0..<8 {
                if bits[index + shift] {
                    byte |= 1 << (7 - shift)
                }
            }
            bytes.append(byte)
            index += 8
        }
        return bytes
    }

    private static func aggregate(_ transmissions: [Transmission], mode: TestMode) -> [PairScore] {
        let groups = Dictionary(grouping: transmissions) { transmission in
            PairKey(low: (transmission.packet.lowHz * 100).rounded(), high: (transmission.packet.highHz * 100).rounded())
        }
        let scores = groups.values.map { items -> PairScore in
            let ordered = items.sorted { $0.packet.sequence < $1.packet.sequence }
            let first = ordered[0].packet
            let snr = mean(ordered.map(\.packetSNRdB))
            let ratio = mean(ordered.map(\.packetRatioDB))
            let passedCount = ordered.filter(\.passed).count
            let passRate = ordered.isEmpty ? 0 : Double(passedCount) / Double(ordered.count)
            return PairScore(
                mode: mode,
                lowHz: first.lowHz,
                highHz: first.highHz,
                meanSNRdB: snr,
                ratioDB: ratio,
                passRate: passRate,
                score: ChannelScore.breakdown(
                    snrDB: snr,
                    ratioDB: ratio,
                    passedCount: passedCount,
                    totalCount: ordered.count
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
