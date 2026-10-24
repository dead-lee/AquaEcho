import Foundation

/// 离线扫描分析器：录音结束后一次性处理。
/// 标记音是所有集合共用的 400 Hz 控制音，位于数据频段之外；
/// 手机只扫这一路标记音，再用载荷里的集合号逐一尝试解调。
enum ScanAnalyzer {
    static func analyze(
        samples: [Float],
        sampleRate: Double,
        config: ScanRunConfig,
        startedAt: Date
    ) -> ScanAnalysis {
        let normalized = config.normalized
        let sets = normalized.activeSets
        let packetsPerSet = max(1, min(200, normalized.packetsPerSet))
        let rate = ScanProtocol.sampleRate
        let audio = resample(samples, from: max(sampleRate, 1), to: rate)

        var logs: [String] = []
        logs.append("分析开始 \(normalized.label) 集合=\(sets.map(\.id).joined(separator: ",")) 每组=\(packetsPerSet) 输入采样率=\(Int(sampleRate.rounded())) 分析采样率=\(Int(rate)) 样本=\(samples.count)")

        var events = markerEvents(audio: audio, sampleRate: rate, thresholdFactor: 5000)
        let expectedTotal = sets.count * packetsPerSet
        if events.count < expectedTotal / 2 {
            logs.append("标记音偏少（\(events.count)/\(expectedTotal)），降低门限重试")
            events = markerEvents(audio: audio, sampleRate: rate, thresholdFactor: 1000)
        }
        logs.append("标记音事件=\(events.count) 标记频率=\(Int(ScanProtocol.markerHz))Hz")

        var byKey: [String: (word: UInt64, snr: Double, marker: Double, sample: Int)] = [:]
        var corruptEvents = 0

        var expectedSetIndex = 0
        for event in events {
            var matched: (set: SpectralSet, word: UInt64, packet: Int, snr: Double, offset: Int)?
            var candidates = [sets[expectedSetIndex]]
            for (index, set) in sets.enumerated() where index != expectedSetIndex {
                candidates.append(set)
            }
            for set in candidates {
                let plan = ScanProtocol.plan(for: set)
                let base = event.startSample + ScanProtocol.dataStartOffset
                if let hit = decode(audio: audio, dataStart: base, plan: plan, set: set, packets: packetsPerSet), hit.valid {
                    matched = (set, hit.word, hit.packetIndex, hit.snrDB, hit.offset)
                    break
                }
            }

            if let matched {
                let key = "\(matched.set.id)#\(matched.packet)"
                let previous = byKey[key]
                if previous == nil || matched.snr > previous!.snr {
                    byKey[key] = (matched.word, matched.snr, event.snrDB, event.startSample)
                }
                logs.append(String(
                    format: "事件 集合=%@ 起始样本=%d 标记SNR=%.1fdB 解出=%@ 包=%d 通过=是 数据SNR=%.1fdB 偏移=%d",
                    locale: Locale(identifier: "en_US_POSIX"),
                    matched.set.id, event.startSample, event.snrDB,
                    ScanPayload.hex(matched.word), matched.packet, matched.snr, matched.offset
                ))
                if let index = sets.firstIndex(where: { $0.id == matched.set.id }) {
                    let nextPacket = matched.packet + 1
                    if nextPacket < packetsPerSet {
                        expectedSetIndex = index
                    } else {
                        expectedSetIndex = (index + 1) % sets.count
                    }
                }
            } else {
                corruptEvents += 1
                logs.append(String(
                    format: "未匹配 起始样本=%d 标记SNR=%.1fdB 说明=所有集合都没通过自校验",
                    locale: Locale(identifier: "en_US_POSIX"),
                    event.startSample, event.snrDB
                ))
            }
        }

        var rows: [ScanPacketResult] = []
        for set in sets {
            for index in 0..<packetsPerSet {
                let expected = ScanPayload.make(setID: set.id, packetIndex: index)
                let key = "\(set.id)#\(index)"
                if let hit = byKey[key] {
                    rows.append(ScanPacketResult(
                        setID: set.id,
                        setTitle: set.title,
                        carrierCount: set.carrierCount,
                        packetIndex: index,
                        expectedHex: ScanPayload.hex(expected),
                        decodedHex: ScanPayload.hex(hit.word),
                        passed: hit.word == expected,
                        detected: true,
                        snrDB: hit.snr,
                        markerSNRDB: hit.marker,
                        airtimeMs: set.airtimeMs,
                        frameSample: hit.sample,
                        timestamp: startedAt.addingTimeInterval(Double(hit.sample) / rate)
                    ))
                } else {
                    rows.append(ScanPacketResult(
                        setID: set.id,
                        setTitle: set.title,
                        carrierCount: set.carrierCount,
                        packetIndex: index,
                        expectedHex: ScanPayload.hex(expected),
                        decodedHex: nil,
                        passed: false,
                        detected: false,
                        snrDB: 0,
                        markerSNRDB: 0,
                        airtimeMs: set.airtimeMs,
                        frameSample: 0,
                        timestamp: nil
                    ))
                    logs.append("缺失 集合=\(set.id) 包=\(index)")
                }
            }
        }

        var summaries: [ScanSetSummary] = []
        for set in sets {
            let setRows = rows.filter { $0.setID == set.id }
            let detectedRows = setRows.filter { $0.detected }
            let passed = setRows.filter { $0.passed }.count
            summaries.append(ScanSetSummary(
                setID: set.id,
                setTitle: set.title,
                carrierCount: set.carrierCount,
                packets: setRows.count,
                detected: detectedRows.count,
                passed: passed,
                successRate: setRows.isEmpty ? 0 : Double(passed) / Double(setRows.count),
                meanSNRDB: mean(detectedRows.map { $0.snrDB }),
                meanMarkerSNRDB: mean(detectedRows.map { $0.markerSNRDB }),
                airtimeMs: set.airtimeMs,
                corrupt: 0
            ))
            logs.append(String(
                format: "汇总 集合=%@ 通过=%d/%d 成功率=%.1f%% 检出=%d 平均SNR=%.1fdB 标记SNR=%.1fdB airtime=%.1fms",
                locale: Locale(identifier: "en_US_POSIX"),
                set.id, passed, setRows.count,
                setRows.isEmpty ? 0 : Double(passed) / Double(setRows.count) * 100,
                detectedRows.count,
                mean(detectedRows.map { $0.snrDB }),
                mean(detectedRows.map { $0.markerSNRDB }),
                set.airtimeMs
            ))
        }

        let overallPackets = rows.count
        let overallPassed = rows.filter { $0.passed }.count
        let overallRate = overallPackets == 0 ? 0 : Double(overallPassed) / Double(overallPackets)
        logs.append(String(
            format: "总汇总 通过=%d/%d 成功率=%.1f%% 未匹配=%d",
            locale: Locale(identifier: "en_US_POSIX"),
            overallPassed, overallPackets, overallRate * 100, corruptEvents
        ))

        return ScanAnalysis(
            config: normalized,
            startedAt: startedAt,
            finishedAt: Date(),
            sampleRate: sampleRate,
            packets: rows,
            summaries: summaries,
            overallPackets: overallPackets,
            overallPassed: overallPassed,
            overallRate: overallRate,
            corruptEvents: corruptEvents,
            logLines: logs
        )
    }

    // MARK: - 标记音

    private struct MarkerEvent {
        var startSample: Int
        var power: Double
        var snrDB: Double
    }

    private static func markerEvents(audio: [Float], sampleRate: Double, thresholdFactor: Double) -> [MarkerEvent] {
        guard audio.count >= ScanProtocol.markerSamples else { return [] }
        let window = ScanProtocol.markerSamples
        let hop = 240 // 5 ms
        let maxStart = audio.count - window
        guard maxStart >= 0 else { return [] }
        let windowCount = maxStart / hop + 1

        var powers = [Double](repeating: 0, count: windowCount)
        for index in 0..<windowCount {
            let start = index * hop
            powers[index] = Goertzel.power(
                samples: audio[start..<(start + window)],
                sampleRate: sampleRate,
                frequency: ScanProtocol.markerHz
            )
        }
        let noise = percentile(powers, 0.20)
        let threshold = max(noise * thresholdFactor, 1e-6)
        var events: [MarkerEvent] = []
        var index = 1
        while index < powers.count {
            guard powers[index] > threshold else {
                index += 1
                continue
            }
            var peak = index
            while index < powers.count, powers[index] > threshold {
                if powers[index] > powers[peak] { peak = index }
                index += 1
            }
            let snr = 10 * log10(max(powers[peak], 1e-20) / max(noise, 1e-20))
            events.append(MarkerEvent(
                startSample: peak * hop,
                power: powers[peak],
                snrDB: snr
            ))
        }
        return events
    }

    // MARK: - 数据帧

    private struct Attempt {
        var word: UInt64
        var packetIndex: Int
        var snrDB: Double
        var offset: Int
        var valid: Bool
    }

    private static func decode(
        audio: [Float],
        dataStart: Int,
        plan: OFDMModem.Plan,
        set: SpectralSet,
        packets: Int
    ) -> Attempt? {
        var best: Attempt?
        let offsets = [0, -48, 48, -96, 96, -144, 144, -192, 192, -240, 240, -288, 288, -336, 336, -384, 384, -432, 432, -480, 480]
        for offset in offsets {
            let start = dataStart + offset
            guard start >= 0, start + plan.packetSamples <= audio.count else { continue }
            guard let demod = OFDMModem.demodulateFrequencyOnly(window: audio, symbolStart: start, plan: plan) else { continue }
            let decoded = ConvolutionalCode.decode(demod.bits)
            guard decoded.count == PacketLayout.bitCount else { continue }
            let word = word(from: decoded)
            let setCode = ScanPayload.setCode(of: word)
            let packet = ScanPayload.packetIndex(of: word)
            let snr = mean(demod.readings.map { $0.snrDB })
            let expected = ScanPayload.make(setCode: setCode, packetIndex: packet)
            let valid = setCode == set.code && packet >= 0 && packet < packets && word == expected
            let attempt = Attempt(word: word, packetIndex: packet, snrDB: snr, offset: offset, valid: valid)
            if valid { return attempt }
            if best == nil || snr > best!.snrDB { best = attempt }
        }
        return best
    }

    private static func word(from bits: [Bool]) -> UInt64 {
        var word: UInt64 = 0
        for bit in bits {
            word = (word << 1) | (bit ? 1 : 0)
        }
        return word
    }

    // MARK: - 工具

    private static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        guard inputRate > 0, outputRate > 0, !samples.isEmpty else { return samples }
        if abs(inputRate - outputRate) < 1 { return samples }
        let count = Int((Double(samples.count) * outputRate / inputRate).rounded(.down))
        guard count > 1 else { return samples }
        var output = [Float](repeating: 0, count: count)
        let scale = inputRate / outputRate
        for index in 0..<count {
            let position = Double(index) * scale
            let lower = min(samples.count - 1, max(0, Int(position)))
            let upper = min(samples.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            output[index] = samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
        return output
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }
}
