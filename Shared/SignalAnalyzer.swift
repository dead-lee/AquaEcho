import Foundation

/// 在麦克风回调的滑动窗口里检出能量突发，立刻测量并解调，不保留整段会话。
enum SignalAnalyzer {
    final class Receiver {
        struct Update {
            var transmission: Transmission
            var processedCount: Int
        }

        var onUpdate: ((Update) -> Void)?
        var onLog: ((String) -> Void)?
        private(set) var retainedSampleCount = 0

        private let config: TestConfig
        private let schedule: [PlannedPair]
        private let lock = NSLock()
        private var sampleRate = 0.0
        private var chunkDate = Date()
        private var chunkMarks: [ChunkMark] = []
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
        private var pendingPackets: [MatchKey: SentPacket] = [:]
        private var pendingHits: [MatchKey: Hit] = [:]
        private var transmissions: [Transmission] = []

        init(config: TestConfig, schedule: [PlannedPair]) {
            self.config = config.normalized
            self.schedule = schedule
        }

        func ingest(_ samples: [Float], at date: Date, sampleRate: Double) {
            guard !samples.isEmpty, sampleRate > 0 else { return }
            let (updates, logs) = locked { () -> ([Update], [String]) in
                if self.sampleRate == 0 { self.sampleRate = sampleRate }
                chunkDate = date
                window.append(contentsOf: samples)
                chunkMarks.append(ChunkMark(absoluteEnd: emitted + window.count, date: date))
                scan()
                trim()
                retainedSampleCount = window.count
                return (drainUpdates(), drainLogs())
            }
            publish(logs: logs, updates: updates)
        }

        func note(_ packet: SentPacket) {
            let (updates, logs) = locked { () -> ([Update], [String]) in
                let key = PacketLayout.matchKey(lowHz: packet.lowHz, highHz: packet.highHz, sequence: packet.repeatIndex)
                let alreadySeen = transmissions.contains { $0.packet.sequence == packet.sequence }
                    || pendingPackets[key]?.sequence == packet.sequence
                if alreadySeen { return (drainUpdates(), drainLogs()) }
                if let hit = pendingHits.removeValue(forKey: key) {
                    record(match(packet: packet, hit: hit))
                } else {
                    pendingPackets[key] = packet
                }
                return (drainUpdates(), drainLogs())
            }
            publish(logs: logs, updates: updates)
        }

        func finish() -> [PairScore] {
            let (scores, logs) = locked { () -> ([PairScore], [String]) in
                if inBurst {
                    closeBurst(end: window.count)
                }
                for packet in pendingPackets.values {
                    transmissions.append(SignalAnalyzer.missed(packet))
                }
                pendingPackets = [:]
                pendingHits = [:]
                window.removeAll(keepingCapacity: false)
                chunkMarks.removeAll(keepingCapacity: false)
                retainedSampleCount = 0
                cursor = 0
                inBurst = false
                return (SignalAnalyzer.aggregate(transmissions, mode: .cpfsk), drainLogs())
            }
            publish(logs: logs, updates: [])
            return scores
        }

        private var queued: [Update] = []
        private var queuedLogs: [String] = []

        private func drainUpdates() -> [Update] {
            let updates = queued
            queued = []
            return updates
        }

        private func drainLogs() -> [String] {
            let lines = queuedLogs
            queuedLogs = []
            return lines
        }

        private func publish(logs: [String], updates: [Update]) {
            if let onLog {
                for line in logs {
                    onLog(line)
                }
            }
            if let onUpdate {
                for update in updates {
                    onUpdate(update)
                }
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
            inBurst = false
            highRun = 0
            lowRun = 0
            guard length >= signalNeed / 2, to > from, sampleRate > 0 else {
                removePrefix(max(to, 1))
                cursor = 0
                queuedLogs.append(SignalAnalyzer.burstLine(decoded: .failed, milliseconds: 0, match: "解调失败"))
                return
            }
            let absoluteFrom = emitted + from
            let slice = Array(window[from..<to])
            let demodStarted = Date()
            let decoded = SignalAnalyzer.demodulatedPayload(
                samples: slice,
                sampleRate: sampleRate,
                f0: low,
                f1: high,
                symbolSeconds: config.symbolDurationMs / 1_000
            )
            let demodEndDate = Date()
            let demodMilliseconds = max(0, Int((demodEndDate.timeIntervalSince(demodStarted) * 1_000).rounded()))
            let receiveDate = decoded.onsetIndex.map { callbackDate(absoluteSample: absoluteFrom + $0) } ?? chunkDate
            removePrefix(to)
            cursor = 0
            let trailSamples = Int((config.trailSilenceMs / 1_000 * sampleRate).rounded())
            removePrefix(min(window.count, symbol * 3, max(0, trailSamples / 2)))
            scheduleIndex += 1
            let fit = SignalAnalyzer.bestBurst(
                region: slice,
                sampleRate: sampleRate,
                f0: low,
                f1: high,
                signalSamples: max(symbol, Int(config.expectedSignalSeconds * sampleRate)),
                window: symbol
            )
            let hit = Hit(
                payload: decoded.payload,
                aligned: decoded.aligned,
                snrDB: fit.snrDB,
                ratioDB: fit.ratioDB,
                detected: fit.snrDB >= 5,
                date: receiveDate,
                demodEndDate: demodEndDate,
                demodMilliseconds: demodMilliseconds,
                burstIndex: scheduleIndex,
                lowHz: low,
                highHz: high,
                decodedLowHz: decoded.lowHz,
                decodedHighHz: decoded.highHz,
                decodedSequence: decoded.sequence,
                corrected: decoded.corrected
            )
            var matched: SentPacket?
            if decoded.aligned, let key = hit.matchKey {
                if let packet = pendingPackets.removeValue(forKey: key) {
                    matched = packet
                } else if pendingHits[key] == nil {
                    pendingHits[key] = hit
                }
            }
            let matchText = decoded.aligned ? (matched == nil ? "无对应包" : "已匹配") : "解调失败"
            queuedLogs.append(SignalAnalyzer.burstLine(decoded: decoded, milliseconds: demodMilliseconds, match: matchText))
            if let matched {
                record(match(packet: matched, hit: hit))
            }
            queuedLogs.append("包 \(scheduleIndex) 结束后窗口剩余 \(window.count) 样本")
        }

        private func callbackDate(absoluteSample: Int) -> Date {
            for mark in chunkMarks where mark.absoluteEnd > absoluteSample {
                return mark.date
            }
            return chunkMarks.last?.date ?? chunkDate
        }

        private func listenFrequencies() -> (Double, Double)? {
            if inBurst { return (burstLow, burstHigh) }
            guard scheduleIndex < schedule.count else { return nil }
            let pair = schedule[scheduleIndex]
            return (pair.lowHz, pair.highHz)
        }

        private func match(packet: SentPacket, hit: Hit) -> Transmission {
            let passed = hit.payload != nil && hit.payload == PacketFactory.data(hex: packet.payloadHex)
            queuedLogs.append(resultLine(hit, passed: passed))
            return Transmission(
                packet: packet,
                phoneReceiveDate: hit.date,
                demodEndDate: hit.demodEndDate,
                packetSNRdB: hit.snrDB,
                packetRatioDB: hit.ratioDB,
                detected: hit.detected,
                passed: passed,
                decodedLowHz: hit.decodedLowHz,
                decodedHighHz: hit.decodedHighHz,
                decodedSequence: hit.decodedSequence,
                errorCorrected: hit.corrected
            )
        }

        private func resultLine(_ hit: Hit, passed: Bool) -> String {
            let aligned = hit.aligned ? "是" : "否"
            let decoded = hit.aligned ? (hit.payload.map(PacketFactory.hex) ?? "空") : "空"
            let ok = passed ? "是" : "否"
            let sequence = hit.decodedSequence.map(String.init) ?? "空"
            let fixed = hit.corrected ? "是" : "否"
            let after = passed ? "是" : "否"
            return "包 \(hit.burstIndex) 前导对齐=\(aligned) 解出=\(decoded) 通过=\(ok) 解调耗时=\(hit.demodMilliseconds)ms 解出序号=\(sequence) 是否纠错=\(fixed) 纠错后是否通过=\(after)"
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
            chunkMarks.removeAll { $0.absoluteEnd <= emitted }
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
        var aligned: Bool
        var snrDB: Double
        var ratioDB: Double
        var detected: Bool
        var date: Date
        var demodEndDate: Date
        var demodMilliseconds: Int
        var burstIndex: Int
        var lowHz: Double
        var highHz: Double
        var decodedLowHz: Double?
        var decodedHighHz: Double?
        var decodedSequence: Int?
        var corrected: Bool

        var matchKey: MatchKey? {
            guard let decodedLowHz, let decodedHighHz, let decodedSequence else { return nil }
            return PacketLayout.matchKey(lowHz: decodedLowHz, highHz: decodedHighHz, sequence: decodedSequence)
        }
    }

    private static func missed(_ packet: SentPacket) -> Transmission {
        Transmission(
            packet: packet,
            phoneReceiveDate: nil,
            demodEndDate: nil,
            packetSNRdB: 0,
            packetRatioDB: 0,
            detected: false,
            passed: false,
            decodedLowHz: nil,
            decodedHighHz: nil,
            decodedSequence: nil,
            errorCorrected: false
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

    private struct ChunkMark {
        var absoluteEnd: Int
        var date: Date
    }

    private struct DemodOutcome {
        var aligned: Bool
        var payload: Data?
        var lowHz: Double?
        var highHz: Double?
        var sequence: Int?
        var corrected: Bool
        var onsetIndex: Int?
        var startOffset: Int?

        static let failed = DemodOutcome(
            aligned: false,
            payload: nil,
            lowHz: nil,
            highHz: nil,
            sequence: nil,
            corrected: false,
            onsetIndex: nil,
            startOffset: nil
        )
    }

    private static func burstLine(decoded: DemodOutcome, milliseconds: Int, match: String) -> String {
        let status = decoded.aligned ? "成功" : "失败"
        let offset = decoded.startOffset.map(String.init) ?? "空"
        let low = decoded.aligned ? (decoded.lowHz.map { String(Int($0.rounded())) } ?? "空") : "空"
        let high = decoded.aligned ? (decoded.highHz.map { String(Int($0.rounded())) } ?? "空") : "空"
        let sequence = decoded.aligned ? (decoded.sequence.map(String.init) ?? "空") : "空"
        let fixed = decoded.corrected ? "是" : "否"
        return "突发 解调=\(status) 起点偏移=\(offset) 解出低频=\(low) 解出高频=\(high) 解出序号=\(sequence) 纠错=\(fixed) 耗时=\(milliseconds)ms 匹配=\(match)"
    }

    /// 用 128 样本能量找 onset，再只在 onset 前 200 到后 600 样本内按 8 样本步进找第一个合格起点。
    private static func demodulatedPayload(
        samples: [Float],
        sampleRate: Double,
        f0: Double,
        f1: Double,
        symbolSeconds: Double
    ) -> DemodOutcome {
        let symbolSamples = max(1, Int((symbolSeconds * sampleRate).rounded()))
        let frameSamples = symbolSamples * PacketLayout.bitCount
        guard frameSamples > 0, let onset = findOnset(samples: samples, sampleRate: sampleRate, f0: f0, f1: f1) else {
            return .failed
        }
        var start = onset - 200
        let last = onset + 600
        while start <= last {
            if start >= 0, start + frameSamples <= samples.count {
                let read = readFrame(
                    samples: samples,
                    sampleRate: sampleRate,
                    offset: start,
                    count: PacketLayout.bitCount,
                    symbolSamples: symbolSamples,
                    f0: f0,
                    f1: f1
                )
                let fixed = ExtendedHamming.correct(word: read.word)
                if fixed.status != .uncorrectable {
                    let fields = PacketLayout.decode(PacketLayout.data(from: read.word))
                    if PacketLayout.frequencyCode(fields.lowHz) == PacketLayout.frequencyCode(f0),
                       PacketLayout.frequencyCode(fields.highHz) == PacketLayout.frequencyCode(f1) {
                        return DemodOutcome(
                            aligned: true,
                            payload: fields.payload,
                            lowHz: fields.lowHz,
                            highHz: fields.highHz,
                            sequence: fields.sequence,
                            corrected: fields.corrected,
                            onsetIndex: onset,
                            startOffset: start - onset
                        )
                    }
                }
            }
            start += 8
        }
        return DemodOutcome(
            aligned: false,
            payload: nil,
            lowHz: nil,
            highHz: nil,
            sequence: nil,
            corrected: false,
            onsetIndex: onset,
            startOffset: nil
        )
    }

    /// 128 样本窗口上两个目标频率的较大 Goertzel 能量超过 0.02，窗口起点就是 onset。
    private static func findOnset(samples: [Float], sampleRate: Double, f0: Double, f1: Double) -> Int? {
        let width = 128
        guard samples.count >= width else { return nil }
        var offset = 0
        while offset + width <= samples.count {
            let window = samples[offset..<(offset + width)]
            let low = Goertzel.power(samples: window, sampleRate: sampleRate, frequency: f0)
            let high = Goertzel.power(samples: window, sampleRate: sampleRate, frequency: f1)
            if max(low, high) > 0.02 {
                return offset
            }
            offset += width
        }
        return nil
    }

    private static func readFrame(
        samples: [Float],
        sampleRate: Double,
        offset: Int,
        count: Int,
        symbolSamples: Int,
        f0: Double,
        f1: Double
    ) -> (word: UInt64, margin: Double) {
        var word: UInt64 = 0
        var margin = 0.0
        for index in 0..<count {
            let start = offset + index * symbolSamples
            let end = start + symbolSamples
            let decision = bitDecision(
                samples: samples[start..<end],
                sampleRate: sampleRate,
                f0: f0,
                f1: f1
            )
            word = (word << 1) | (decision.one ? 1 : 0)
            margin += decision.margin
        }
        return (word, margin)
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
