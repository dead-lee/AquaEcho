import Foundation

/// 在滑动窗口里用 Naiser 前导找到 OFDM 包，卷积译码还原 64 bit 载荷。
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
        private var searchFrom = 0
        private var hopCounter = 0
        private var cachedPlan: OFDMModem.Plan?
        private var cachedLow = -1.0
        private var cachedHigh = -1.0
        private var heard: [Float] = []
        private var heardCount = -1
        private var heardLow = -1.0
        private var heardHigh = -1.0
        private var correlation: [Float] = []
        private var bits: [Bool] = []
        private var firstBitDate: Date?
        private var firstBitWall: Date?
        private var frameReadings: [WindowReading] = []
        private var pendingWindowLogIndex: Int?
        private var peakSNR = -Double.infinity
        private var peakRatio = 0.0
        private var peakSamples = 0
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
                flushWindowLog()
                for packet in pendingPackets.values {
                    transmissions.append(SignalAnalyzer.missed(packet))
                }
                pendingPackets = [:]
                pendingHits = [:]
                window.removeAll(keepingCapacity: false)
                chunkMarks.removeAll(keepingCapacity: false)
                retainedSampleCount = 0
                bits.removeAll(keepingCapacity: false)
                cachedPlan = nil
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
            for line in logs { onLog?(line) }
            for update in updates { onUpdate?(update) }
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        private func scan() {
            while true {
                guard let pair = currentPair(), let plan = currentPlan(low: pair.0, high: pair.1) else { return }
                let audio = filteredWindow(low: pair.0, high: pair.1, preamble: plan.preamble)
                let symbolCount = 1 + plan.dataCounts.count
                guard emitted + audio.count >= searchFrom + plan.packetSamples else { return }
                let localStart = searchFrom - emitted
                guard localStart >= 0 else {
                    searchFrom = emitted
                    continue
                }
                let lastLag = audio.count - plan.preamble.count
                let searchEnd = min(lastLag, audio.count - plan.packetSamples + OFDMModem.naiserWindow)
                guard searchEnd >= localStart else { return }
                let candidates = candidateLocals(from: localStart, through: searchEnd, separation: 2_400, symbolLength: plan.ns)
                if candidates.isEmpty {
                    consume(upToLocal: searchEnd, plan: plan, pair: pair)
                    trim()
                    return
                }
                var accepted = false
                var rejectedLocal = localStart
                for candidate in candidates {
                    guard OFDMModem.naiserLock(samples: audio, peakIndex: candidate) != nil else {
                        rejectedLocal = max(rejectedLocal, candidate + 2_400)
                        continue
                    }
                    // evalSegv2 只用 Naiser 当门限，符号起点用相关峰本身。
                    let symbolStart = candidate + plan.preamble.count + plan.gap
                    let packetEndLocal = symbolStart + symbolCount * plan.symbolSamples
                    if packetEndLocal > audio.count {
                        consume(upToLocal: candidate, plan: plan, pair: pair)
                        return
                    }
                    if let demod = OFDMModem.demodulate(window: audio, symbolStart: symbolStart, plan: plan) {
                        accept(demod, preambleAbsolute: emitted + candidate)
                        let packetEnd = emitted + symbolStart + symbolCount * plan.symbolSamples
                        noteSkipped(from: searchFrom, to: packetEnd)
                        searchFrom = packetEnd
                        trim()
                        flushWindowLog()
                        accepted = true
                        break
                    }
                    rejectedLocal = max(rejectedLocal, candidate + 2_400)
                }
                if accepted { continue }
                let nextLocal = min(rejectedLocal, searchEnd)
                if emitted + nextLocal <= searchFrom {
                    consume(upToLocal: searchEnd, plan: plan, pair: pair)
                    trim()
                    return
                }
                consume(upToLocal: nextLocal, plan: plan, pair: pair)
                trim()
            }
        }

        private func filteredWindow(low: Double, high: Double, preamble: [Float]) -> [Float] {
            if heardCount != window.count || heardLow != low || heardHigh != high {
                heard = OFDMModem.bandpass(window, lowHz: low, highHz: high, sampleRate: sampleRate)
                correlation = OFDMModem.correlate(signal: heard, template: preamble)
                heardCount = window.count
                heardLow = low
                heardHigh = high
            }
            return heard
        }

        /// getCandidateLocs 再加 find_symbol.m 的尖峰检查：±1000 点里超过半峰的个数太多就丢掉。
        /// 不尖的峰只清掉半峰以上的那一段，避免把旁边真正的前导一起盖住。
        private func candidateLocals(from: Int, through: Int, separation: Int, symbolLength: Int) -> [Int] {
            guard through >= from, !correlation.isEmpty else { return [] }
            var work = correlation
            var chosen: [Int] = []
            let upper = min(through, work.count - 1)
            let sharpLimit = symbolLength <= 960 ? 150 : 80
            var inspections = 0
            while chosen.count < 3, inspections < 12 {
                inspections += 1
                var best = Float(0)
                var bestAt = -1
                var index = from
                while index <= upper {
                    if work[index] > best {
                        best = work[index]
                        bestAt = index
                    }
                    index += 1
                }
                guard bestAt >= 0 else { break }
                if sharpCount(around: bestAt, in: work, height: best * 0.5) <= sharpLimit {
                    chosen.append(bestAt)
                    let low = max(0, bestAt - separation)
                    let high = min(work.count, bestAt + separation + 1)
                    for index in low..<high {
                        work[index] = 0
                    }
                } else {
                    suppressLobe(around: bestAt, in: &work, height: best * 0.5)
                }
            }
            return chosen.sorted()
        }

        private func sharpCount(around index: Int, in values: [Float], height: Float) -> Int {
            let from = max(0, index - 1_000)
            let to = min(values.count - 1, index + 1_000)
            var count = 0
            for sample in from...to where values[sample] > height {
                count += 1
            }
            return count
        }

        private func suppressLobe(around index: Int, in values: inout [Float], height: Float) {
            var low = index
            while low > 0, values[low - 1] > height {
                low -= 1
            }
            var high = index
            while high + 1 < values.count, values[high + 1] > height {
                high += 1
            }
            for sample in low...high {
                values[sample] = 0
            }
        }

        private func consume(upToLocal: Int, plan: OFDMModem.Plan, pair: (Double, Double)) {
            let target = emitted + upToLocal
            while searchFrom + plan.coarseHop <= target {
                let local = searchFrom - emitted
                observeHop(local: local, plan: plan, pair: pair)
                searchFrom += plan.coarseHop
            }
        }

        private func noteSkipped(from: Int, to: Int) {
            let skipped = to - from
            guard skipped > 0 else { return }
            notePeak(WindowReading(snrDB: -10, ratioDB: 0), hopSamples: skipped)
        }

        private func observeHop(local: Int, plan: OFDMModem.Plan, pair: (Double, Double)) {
            hopCounter += 1
            if hopCounter % 4 == 0, local >= 0, local + 384 <= window.count {
                let reading = SignalAnalyzer.measureWindow(
                    samples: window[local..<(local + 384)],
                    sampleRate: sampleRate,
                    f0: pair.0,
                    f1: pair.1
                )
                notePeak(reading, hopSamples: plan.coarseHop)
            } else {
                notePeak(WindowReading(snrDB: -10, ratioDB: 0), hopSamples: plan.coarseHop)
            }
        }

        private func accept(_ demod: OFDMModem.Demodulated, preambleAbsolute: Int) {
            guard demod.bits.count == ConvolutionalCode.encodedBitCount else { return }
            firstBitDate = callbackDate(absoluteSample: preambleAbsolute)
            firstBitWall = Date()
            frameReadings = demod.readings.map { WindowReading(snrDB: $0.snrDB, ratioDB: $0.ratioDB) }
            bits = demod.bits
            finalizeFrame()
        }

        private func currentPlan(low: Double, high: Double) -> OFDMModem.Plan? {
            if cachedPlan == nil || cachedLow != low || cachedHigh != high {
                cachedPlan = OFDMModem.plan(
                    f0: low,
                    f1: high,
                    config: config,
                    bitCount: ConvolutionalCode.encodedBitCount
                )
                cachedLow = low
                cachedHigh = high
            }
            return cachedPlan
        }

        private func finalizeFrame() {
            let demodEndDate = Date()
            let demodMilliseconds = max(0, Int((demodEndDate.timeIntervalSince(firstBitWall ?? demodEndDate) * 1_000).rounded()))
            let decoded = ConvolutionalCode.decode(bits)
            guard decoded.count == PacketLayout.bitCount else {
                bits = []
                frameReadings = []
                firstBitDate = nil
                firstBitWall = nil
                return
            }
            let recoded = ConvolutionalCode.encode(decoded)
            let corrected = zip(bits, recoded).contains { $0 != $1 }
            var word: UInt64 = 0
            for bit in decoded {
                word = (word << 1) | (bit ? 1 : 0)
            }
            let lowCode = Int((word >> 54) & 0x3FF)
            let highCode = Int((word >> 44) & 0x3FF)
            let sequence = Int((word >> 41) & 0x7)
            let lowHz = Double(lowCode * 50)
            let highHz = Double(highCode * 50)
            let payload = PacketLayout.data(from: word)
            let listening = currentPair()
            let frequencyMatched = listening.map { pair in
                PacketLayout.frequencyCode(lowHz) == PacketLayout.frequencyCode(pair.0)
                    && PacketLayout.frequencyCode(highHz) == PacketLayout.frequencyCode(pair.1)
            } ?? false
            let checksumPassed = frequencyMatched
            let success = frequencyMatched
            let fit = SignalAnalyzer.combine(frameReadings)
            let receiveDate = firstBitDate ?? chunkDate
            bits = []
            frameReadings = []
            firstBitDate = nil
            firstBitWall = nil
            if frequencyMatched {
                scheduleIndex += 1
                pendingWindowLogIndex = scheduleIndex
            }
            let hit = Hit(
                payload: payload,
                aligned: success,
                snrDB: fit.snrDB,
                ratioDB: fit.ratioDB,
                detected: fit.snrDB >= 5,
                date: receiveDate,
                demodEndDate: demodEndDate,
                demodMilliseconds: demodMilliseconds,
                burstIndex: scheduleIndex,
                lowHz: listening?.0 ?? lowHz,
                highHz: listening?.1 ?? highHz,
                decodedLowHz: lowHz,
                decodedHighHz: highHz,
                decodedSequence: sequence,
                corrected: corrected
            )
            var matched: SentPacket?
            let matchText: String
            if let key = hit.matchKey, checksumPassed && frequencyMatched {
                if let packet = pendingPackets.removeValue(forKey: key) {
                    matched = packet
                } else if pendingHits[key] == nil {
                    pendingHits[key] = hit
                }
                matchText = matched == nil ? "无对应包" : "已匹配"
            } else if let key = hit.matchKey, !checksumPassed {
                if let packet = pendingPackets.removeValue(forKey: key) {
                    matched = packet
                } else if pendingHits[key] == nil {
                    pendingHits[key] = hit
                }
                matchText = "校验失败"
            } else {
                matchText = "无对应包"
            }
            queuedLogs.append(SignalAnalyzer.demodLine(
                success: success,
                lowHz: lowHz,
                highHz: highHz,
                sequence: sequence,
                corrected: corrected,
                checksumPassed: checksumPassed,
                hex: PacketFactory.hex(payload),
                milliseconds: demodMilliseconds,
                match: matchText
            ))
            if let matched {
                record(match(packet: matched, hit: hit))
            }
        }

        private func notePeak(_ reading: WindowReading, hopSamples: Int) {
            if reading.snrDB >= peakSNR {
                peakSNR = reading.snrDB
                peakRatio = reading.ratioDB
            }
            peakSamples += hopSamples
            let samplesPerSecond = max(1, Int(sampleRate.rounded()))
            while peakSamples >= samplesPerSecond {
                queuedLogs.append(String(
                    format: "检测峰值 SNR=%.1f 能量比=%.1f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    peakSNR,
                    peakRatio
                ))
                peakSNR = -.infinity
                peakRatio = 0
                peakSamples -= samplesPerSecond
            }
        }

        private func flushWindowLog() {
            guard let index = pendingWindowLogIndex else { return }
            pendingWindowLogIndex = nil
            queuedLogs.append("包 \(index) 结束后窗口剩余 \(window.count) 样本")
        }

        private func callbackDate(absoluteSample: Int) -> Date {
            for mark in chunkMarks where mark.absoluteEnd > absoluteSample {
                return mark.date
            }
            return chunkMarks.last?.date ?? chunkDate
        }

        private func currentPair() -> (Double, Double)? {
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
            chunkMarks.removeAll { $0.absoluteEnd <= emitted }
        }

        private func trim() {
            let lookback = cachedPlan?.preamble.count ?? 0
            let dropTo = searchFrom - lookback
            if dropTo > emitted {
                removePrefix(dropTo - emitted)
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
        var highDominant: Bool = false
        var signalPower: Double = 0
    }

    private static func demodLine(
        success: Bool,
        lowHz: Double,
        highHz: Double,
        sequence: Int,
        corrected: Bool,
        checksumPassed: Bool,
        hex: String,
        milliseconds: Int,
        match: String
    ) -> String {
        let status = success ? "成功" : "失败"
        let low = String(Int(lowHz.rounded()))
        let high = String(Int(highHz.rounded()))
        let fixed = corrected ? "是" : "否"
        let check = checksumPassed ? "通过" : "失败"
        return "解调=\(status) 解出低频=\(low) 解出高频=\(high) 解出序号=\(sequence) 纠错=\(fixed) 校验=\(check) 解出hex=\(hex) 耗时=\(milliseconds)ms 匹配=\(match)"
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
        } / Double(max(noiseBins.count, 1))
        let signal = max(p0, p1)
        let inactive = max(min(p0, p1), 1e-20)
        let noise = max(noisePower, 1e-20)
        let snr = (10 * log10(max(signal, 1e-20) / noise)).clamped(to: -10...80)
        let ratio = (10 * log10(max(signal, 1e-20) / inactive)).clamped(to: 0...60)
        return WindowReading(snrDB: snr, ratioDB: ratio, highDominant: p1 > p0, signalPower: signal)
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
