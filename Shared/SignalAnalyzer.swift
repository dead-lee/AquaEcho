import Foundation

/// 在麦克风回调的滑动窗口里按脉宽收 bit，攒满 64 bit 后校验，不保留整段会话。
enum SignalAnalyzer {
    private static let toneSNRdB = 6.0
    private static let toneRatioDB = 8.0
    private static let minPulseMilliseconds = 25.0
    private static let mergeGapMilliseconds = 12.0

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
        private var openPulse: OpenPulse?
        private var oppositeHigh: Bool?
        private var oppositeCount = 0
        private var oppositeStart = 0
        private var oppositeSamples: [Float] = []
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
                if openPulse != nil {
                    closePulse()
                }
                oppositeHigh = nil
                oppositeCount = 0
                oppositeSamples = []
                flushWindowLog()
                for packet in pendingPackets.values {
                    transmissions.append(SignalAnalyzer.missed(packet))
                }
                pendingPackets = [:]
                pendingHits = [:]
                window.removeAll(keepingCapacity: false)
                chunkMarks.removeAll(keepingCapacity: false)
                retainedSampleCount = 0
                openPulse = nil
                bits.removeAll(keepingCapacity: false)
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
            let analysisSamples = max(1, Int((10.0 / 1_000 * sampleRate).rounded()))
            let hopSamples = max(1, Int((4.0 / 1_000 * sampleRate).rounded()))
            let mergeGap = max(1, Int((SignalAnalyzer.mergeGapMilliseconds / 1_000 * sampleRate).rounded()))
            while window.count >= analysisSamples {
                guard let frequencies = currentPair() else { return }
                let slice = window[0..<analysisSamples]
                let reading = SignalAnalyzer.measureWindow(
                    samples: slice,
                    sampleRate: sampleRate,
                    f0: frequencies.0,
                    f1: frequencies.1
                )
                notePeak(reading, hopSamples: hopSamples)
                let absStart = emitted
                // 段的时间用分析窗起点。10 ms 窗会提前看到下一个音，起点到起点才能把 20 ms 静音量成不小于 12 ms 的缺口。
                let absEnd = absStart
                let tone = reading.snrDB >= SignalAnalyzer.toneSNRdB && reading.ratioDB >= SignalAnalyzer.toneRatioDB
                // 和当前段比，而不是和绝对能量比。静音里两个目标频率的比值偶尔也能过 8 dB，但功率比这段音调低几十 dB，不能拿来续段或切段。
                let holdsTone = openPulse.map { reading.signalPower >= $0.referencePower * 1e-3 } ?? true
                if tone && holdsTone {
                    let isHigh = reading.highDominant
                    if let pulse = openPulse, pulse.isHigh != isHigh {
                        if oppositeHigh == isHigh {
                            oppositeCount += 1
                            oppositeSamples.append(contentsOf: slice)
                        } else {
                            oppositeHigh = isHigh
                            oppositeCount = 1
                            oppositeStart = absStart
                            oppositeSamples = Array(slice)
                        }
                        if oppositeCount >= 2 {
                            absorbTone(
                                isHigh: isHigh,
                                absStart: oppositeStart,
                                absEnd: absEnd,
                                samples: oppositeSamples,
                                power: reading.signalPower,
                                mergeGap: mergeGap
                            )
                            oppositeHigh = nil
                            oppositeCount = 0
                            oppositeSamples = []
                        }
                    } else {
                        oppositeHigh = nil
                        oppositeCount = 0
                        oppositeSamples = []
                        absorbTone(
                            isHigh: isHigh,
                            absStart: absStart,
                            absEnd: absEnd,
                            samples: Array(slice),
                            power: reading.signalPower,
                            mergeGap: mergeGap
                        )
                    }
                } else {
                    oppositeHigh = nil
                    oppositeCount = 0
                    oppositeSamples = []
                    if let pulse = openPulse, absStart - pulse.toneEnd >= mergeGap {
                        closePulse()
                    }
                }
                removePrefix(hopSamples)
                flushWindowLog()
            }
        }

        /// 同频率且缺口小于 12 ms 时先并进当前段，时长留到这段真正结束再判断。
        private func absorbTone(isHigh: Bool, absStart: Int, absEnd: Int, samples: [Float], power: Double, mergeGap: Int) {
            if let pulse = openPulse {
                let gap = absStart - pulse.toneEnd
                if pulse.isHigh == isHigh && gap < mergeGap {
                    openPulse?.toneEnd = absEnd
                    openPulse?.referencePower = max(pulse.referencePower, power)
                    openPulse?.samples.append(contentsOf: samples)
                    return
                }
                closePulse()
            }
            openPulse = OpenPulse(
                isHigh: isHigh,
                start: absStart,
                toneEnd: absEnd,
                startDate: callbackDate(absoluteSample: absStart),
                referencePower: power,
                samples: samples
            )
        }

        private func closePulse() {
            guard let pulse = openPulse else { return }
            openPulse = nil
            let minSamples = max(1, Int((SignalAnalyzer.minPulseMilliseconds / 1_000 * sampleRate).rounded()))
            let durationMs = max(0, Int((Double(pulse.toneEnd - pulse.start) / sampleRate * 1_000).rounded()))
            guard pulse.toneEnd - pulse.start >= minSamples else {
                let band = pulse.isHigh ? "高" : "低"
                queuedLogs.append("丢弃脉冲 频率=\(band) 持续=\(durationMs)ms 原因=短于25ms")
                return
            }
            if bits.isEmpty {
                firstBitDate = pulse.startDate
                firstBitWall = Date()
                frameReadings = []
            }
            bits.append(pulse.isHigh)
            if let frequencies = currentPair(), !pulse.samples.isEmpty {
                frameReadings.append(SignalAnalyzer.measureWindow(
                    samples: pulse.samples[...],
                    sampleRate: sampleRate,
                    f0: frequencies.0,
                    f1: frequencies.1
                ))
            }
            if bits.count == PacketLayout.bitCount {
                finalizeFrame()
            }
        }

        private func finalizeFrame() {
            let demodEndDate = Date()
            let demodMilliseconds = max(0, Int((demodEndDate.timeIntervalSince(firstBitWall ?? demodEndDate) * 1_000).rounded()))
            var word: UInt64 = 0
            for bit in bits {
                word = (word << 1) | (bit ? 1 : 0)
            }
            let fixed = ExtendedHamming.correct(word: word)
            let lowCode = Int((fixed.word >> 54) & 0x3FF)
            let highCode = Int((fixed.word >> 44) & 0x3FF)
            let sequence = Int((fixed.word >> 41) & 0x7)
            let lowHz = Double(lowCode * 50)
            let highHz = Double(highCode * 50)
            let payload = PacketLayout.data(from: fixed.word)
            let checksumPassed = fixed.status != .uncorrectable
            let listening = currentPair()
            let frequencyMatched = listening.map { pair in
                PacketLayout.frequencyCode(lowHz) == PacketLayout.frequencyCode(pair.0)
                    && PacketLayout.frequencyCode(highHz) == PacketLayout.frequencyCode(pair.1)
            } ?? false
            let success = checksumPassed && frequencyMatched
            let fit = SignalAnalyzer.combine(frameReadings)
            let receiveDate = firstBitDate ?? chunkDate
            bits = []
            frameReadings = []
            firstBitDate = nil
            firstBitWall = nil
            scheduleIndex += 1
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
                corrected: fixed.corrected
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
                corrected: fixed.corrected,
                checksumPassed: checksumPassed,
                hex: PacketFactory.hex(payload),
                milliseconds: demodMilliseconds,
                match: matchText
            ))
            if let matched {
                record(match(packet: matched, hit: hit))
            }
            pendingWindowLogIndex = scheduleIndex
        }

        private func notePeak(_ reading: WindowReading, hopSamples: Int) {
            if reading.snrDB >= peakSNR {
                peakSNR = reading.snrDB
                peakRatio = reading.ratioDB
            }
            peakSamples += hopSamples
            let samplesPerSecond = max(1, Int(sampleRate.rounded()))
            guard peakSamples >= samplesPerSecond else { return }
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
            guard openPulse == nil, bits.isEmpty, sampleRate > 0 else { return }
            let cap = max(8_192, Int((config.expectedSignalSeconds + 1) * sampleRate))
            if window.count > cap {
                removePrefix(window.count - cap)
            }
        }

        private struct OpenPulse {
            var isHigh: Bool
            var start: Int
            var toneEnd: Int
            var startDate: Date
            var referencePower: Double
            var samples: [Float]
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
        } / Double(noiseBins.count)
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
