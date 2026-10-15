import Foundation

/// 在麦克风回调的滑动窗口里检出能量突发，立刻测量并解调，不保留整段会话。
enum SignalAnalyzer {
    final class Receiver {
        struct Update {
            var transmission: Transmission
            var processedCount: Int
        }

        var onUpdate: ((Update) -> Void)?
        private(set) var retainedSampleCount = 0

        private let config: TestConfig
        private let schedule: [PlannedPair]
        private let lock = NSLock()
        private var sampleRate = 0.0
        private var sessionStart: Date?
        private var window: [Float] = []
        private var emitted = 0
        private var cursor = 0
        private var inBurst = false
        private var burstStart = 0
        private var burstLow = 0.0
        private var burstHigh = 0.0
        private var highRun = 0
        private var lowRun = 0
        private var scheduleIndex = 0
        private var pendingPackets: [SentPacket] = []
        private var pendingHits: [Hit] = []
        private var transmissions: [Transmission] = []

        init(config: TestConfig, schedule: [PlannedPair]) {
            self.config = config.normalized
            self.schedule = schedule
        }

        func ingest(_ samples: [Float], at date: Date, sampleRate: Double) {
            guard !samples.isEmpty, sampleRate > 0 else { return }
            let updates = locked {
                if self.sampleRate == 0 { self.sampleRate = sampleRate }
                if sessionStart == nil { sessionStart = date }
                window.append(contentsOf: samples)
                scan()
                trim()
                retainedSampleCount = window.count
                return drainUpdates()
            }
            publish(updates)
        }

        func note(_ packet: SentPacket) {
            let updates = locked {
                let alreadySeen = transmissions.contains { $0.packet.sequence == packet.sequence }
                    || pendingPackets.contains { $0.sequence == packet.sequence }
                if alreadySeen { return drainUpdates() }
                if let hit = pendingHits.first {
                    pendingHits.removeFirst()
                    record(match(packet: packet, hit: hit))
                } else {
                    pendingPackets.append(packet)
                }
                return drainUpdates()
            }
            publish(updates)
        }

        func finish() -> [PairScore] {
            locked {
                if inBurst {
                    closeBurst(end: window.count)
                }
                for packet in pendingPackets {
                    transmissions.append(SignalAnalyzer.missed(packet))
                }
                pendingPackets = []
                pendingHits = []
                window.removeAll(keepingCapacity: false)
                retainedSampleCount = 0
                cursor = 0
                inBurst = false
                return SignalAnalyzer.aggregate(transmissions, mode: .cpfsk)
            }
        }

        private var queued: [Update] = []

        private func drainUpdates() -> [Update] {
            let updates = queued
            queued = []
            return updates
        }

        private func publish(_ updates: [Update]) {
            guard let onUpdate else { return }
            for update in updates {
                onUpdate(update)
            }
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        private func scan() {
            guard sampleRate > 0 else { return }
            let symbol = max(256, Int((config.symbolDurationMs / 1_000 * sampleRate).rounded()))
            let hop = max(128, symbol / 2)
            let signalNeed = max(symbol, Int(config.expectedSignalSeconds * sampleRate))
            let trailNeed = Int((config.trailSilenceMs / 1_000 * sampleRate).rounded())
            var guardHops = 0
            while cursor + symbol <= window.count, guardHops < 8_000 {
                guardHops += 1
                guard let frequencies = listenFrequencies() else { return }
                let reading = SignalAnalyzer.measureWindow(
                    samples: window[cursor..<(cursor + symbol)],
                    sampleRate: sampleRate,
                    f0: frequencies.0,
                    f1: frequencies.1
                )
                if !inBurst {
                    let tone = reading.snrDB >= 6 && reading.ratioDB >= 8
                    if tone {
                        if highRun == 0 { burstStart = cursor }
                        highRun += 1
                        if highRun >= 2 {
                            inBurst = true
                            burstLow = frequencies.0
                            burstHigh = frequencies.1
                            lowRun = 0
                        }
                    } else {
                        highRun = 0
                        let keep = max(0, cursor - hop)
                        if keep > hop * 2 {
                            removePrefix(keep)
                        }
                    }
                } else {
                    lowRun = reading.snrDB < 5 ? lowRun + 1 : 0
                    let length = cursor - burstStart
                    let finished = length >= signalNeed && lowRun >= 2
                    let overflow = length >= signalNeed + trailNeed + symbol
                    if finished || overflow {
                        closeBurst(end: min(window.count, cursor + symbol))
                        continue
                    }
                }
                cursor += hop
            }
        }

        private func closeBurst(end: Int) {
            let symbol = max(256, Int((config.symbolDurationMs / 1_000 * sampleRate).rounded()))
            let hop = max(128, symbol / 2)
            let signalNeed = max(symbol, Int(config.expectedSignalSeconds * sampleRate))
            let from = max(0, burstStart - hop)
            let to = min(window.count, max(end, burstStart + symbol))
            let length = to - burstStart
            let low = burstLow
            let high = burstHigh
            let absolute = emitted + burstStart
            inBurst = false
            highRun = 0
            lowRun = 0
            guard length >= signalNeed / 2, to > from, sampleRate > 0 else {
                removePrefix(max(to, 1))
                cursor = 0
                return
            }
            let slice = Array(window[from..<to])
            let offset = burstStart - from
            removePrefix(to)
            cursor = 0
            scheduleIndex += 1
            let started = sessionStart ?? Date()
            let fit = SignalAnalyzer.bestBurst(
                region: slice,
                sampleRate: sampleRate,
                f0: low,
                f1: high,
                signalSamples: max(symbol, Int(config.expectedSignalSeconds * sampleRate)),
                window: symbol
            )
            let decoded = SignalAnalyzer.demodulatedPayload(
                samples: slice,
                sampleRate: sampleRate,
                burstStart: offset,
                f0: low,
                f1: high,
                symbolSeconds: config.symbolDurationMs / 1_000
            )
            let hit = Hit(
                payload: decoded,
                snrDB: fit.snrDB,
                ratioDB: fit.ratioDB,
                detected: fit.snrDB >= 5,
                date: started.addingTimeInterval(Double(absolute) / sampleRate),
                lowHz: low,
                highHz: high
            )
            if pendingPackets.isEmpty {
                pendingHits.append(hit)
            } else {
                let packet = pendingPackets.removeFirst()
                record(match(packet: packet, hit: hit))
            }
        }

        private func listenFrequencies() -> (Double, Double)? {
            if inBurst { return (burstLow, burstHigh) }
            if let packet = pendingPackets.first {
                return (packet.lowHz, packet.highHz)
            }
            guard scheduleIndex < schedule.count else { return nil }
            let pair = schedule[scheduleIndex]
            return (pair.lowHz, pair.highHz)
        }

        private func match(packet: SentPacket, hit: Hit) -> Transmission {
            let passed = hit.payload != nil && hit.payload == PacketFactory.data(hex: packet.payloadHex)
            return Transmission(
                packet: packet,
                phoneReceiveDate: hit.date,
                packetSNRdB: hit.snrDB,
                packetRatioDB: hit.ratioDB,
                detected: hit.detected,
                passed: passed
            )
        }

        private func record(_ transmission: Transmission) {
            transmissions.append(transmission)
            queued.append(Update(transmission: transmission, processedCount: transmissions.count))
        }

        private func removePrefix(_ count: Int) {
            let n = min(max(0, count), window.count)
            guard n > 0 else { return }
            window.removeFirst(n)
            emitted += n
            cursor = max(0, cursor - n)
            burstStart = max(0, burstStart - n)
        }

        private func trim() {
            guard !inBurst, sampleRate > 0 else { return }
            let cap = max(8_192, Int((config.expectedSignalSeconds + 1) * sampleRate))
            if window.count > cap {
                removePrefix(window.count - cap)
            }
        }
    }

    private struct Hit {
        var payload: Data?
        var snrDB: Double
        var ratioDB: Double
        var detected: Bool
        var date: Date
        var lowHz: Double
        var highHz: Double
    }

    private static func missed(_ packet: SentPacket) -> Transmission {
        Transmission(
            packet: packet,
            phoneReceiveDate: nil,
            packetSNRdB: 0,
            packetRatioDB: 0,
            detected: false,
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
