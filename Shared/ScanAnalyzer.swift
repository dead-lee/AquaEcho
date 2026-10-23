import Foundation

/// 离线扫描分析器：录音结束后一次性处理，不依赖实时同步。
/// 1. 在整段录音里找每个集合的标记音（30 ms 单音），得到帧起点和集合；
/// 2. 从帧起点后 40 ms 开始，用该集合的子载波做差分 OFDM 解调；
/// 3. 维特比译码后按 (集合号, 包序号) 重建期望 64 bit，逐 bit 比对；
/// 4. 按集合/包补齐缺失行，输出成功率和每包日志。
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

        let events = markerEvents(audio: audio, sets: sets, sampleRate: rate)
        logs.append("标记音事件=\(events.count)")

        var byKey: [String: (word: UInt64, snr: Double, marker: Double, sample: Int)] = [:]
        var corruptBySet: [String: Int] = [:]
        var corruptEvents = 0

        for event in events {
            let set = event.set
            let plan = ScanProtocol.plan(for: set)
            let base = event.startSample + ScanProtocol.dataStartOffset
            let attempt = decode(audio: audio, dataStart: base, plan: plan, set: set, packets: packetsPerSet)

            if let attempt, attempt.valid {
                let key = "\(set.id)#\(attempt.packetIndex)"
                let previous = byKey[key]
                if previous == nil || attempt.snrDB > previous!.snr {
                    byKey[key] = (attempt.word, attempt.snrDB, event.snrDB, event.startSample)
                }
                logs.append(String(
                    format: "事件 集合=%@ 起始样本=%d 标记SNR=%.1fdB 解出=%@ 包=%d 通过=是 数据SNR=%.1fdB 偏移=%d",
                    locale: Locale(identifier: "en_US_POSIX"),
                    set.id, event.startSample, event.snrDB,
                    ScanPayload.hex(attempt.word), attempt.packetIndex,
                    attempt.snrDB, attempt.offset
                ))
            } else {
                corruptEvents += 1
                corruptBySet[set.id, default: 0] += 1
                let word = attempt?.word ?? 0
                let snr = attempt?.snrDB ?? 0
                logs.append(String(
                    format: "伪包/失败 集合=%@ 起始样本=%d 标记SNR=%.1fdB 解出=%@ 数据SNR=%.1fdB 说明=未通过自校验",
                    locale: Locale(identifier: "en_US_POSIX"),
                    set.id, event.startSample, event.snrDB,
                    ScanPayload.hex(word), snr
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
                corrupt: corruptBySet[set.id] ?? 0
            ))
            logs.append(String(
                format: "汇总 集合=%@ 通过=%d/%d 成功率=%.1f%% 检出=%d 伪包=%d 平均SNR=%.1fdB 标记SNR=%.1fdB airtime=%.1fms",
                locale: Locale(identifier: "en_US_POSIX"),
                set.id, passed, setRows.count,
                setRows.isEmpty ? 0 : Double(passed) / Double(setRows.count) * 100,
                detectedRows.count, corruptBySet[set.id] ?? 0,
                mean(detectedRows.map { $0.snrDB }),
                mean(detectedRows.map { $0.markerSNRDB }),
                set.airtimeMs
            ))
        }

        let overallPackets = rows.count
        let overallPassed = rows.filter { $0.passed }.count
        let overallRate = overallPackets == 0 ? 0 : Double(overallPassed) / Double(overallPackets)
        logs.append(String(
            format: "总汇总 通过=%d/%d 成功率=%.1f%% 伪包=%d",
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
        var set: SpectralSet
        var power: Double
        var snrDB: Double
    }

    private static func markerEvents(audio: [Float], sets: [SpectralSet], sampleRate: Double) -> [MarkerEvent] {
        guard audio.count >= ScanProtocol.markerSamples else { return [] }
        let window = ScanProtocol.markerSamples
        let hop = 240 // 5 ms
        let maxStart = audio.count - window
        guard maxStart >= 0 else { return [] }
        let windowCount = maxStart / hop + 1

        var perSet: [[MarkerEvent]] = []
        for set in sets {
            var powers = [Double](repeating: 0, count: windowCount)
            for index in 0..<windowCount {
                let start = index * hop
                powers[index] = Goertzel.power(
                    samples: audio[start..<(start + window)],
                    sampleRate: sampleRate,
                    frequency: set.markerHz
                )
            }
            let noise = percentile(powers, 0.20)
            let threshold = max(noise * 10, 1e-6)
            var events: [MarkerEvent] = []
            var index = 0
            while index < powers.count {
                let previous = index > 0 ? powers[index - 1] : -Double.infinity
                let next = index + 1 < powers.count ? powers[index + 1] : -Double.infinity
                if powers[index] >= threshold,
                   powers[index] >= previous,
                   powers[index] >= next {
                    var peak = index
                    let upper = min(index + 4, powers.count - 1)
                    if index + 1 <= upper {
                        for probe in (index + 1)...upper where powers[probe] > powers[peak] {
                            peak = probe
                        }
                    }
                    let snr = 10 * log10(max(powers[peak], 1e-20) / max(noise, 1e-20))
                    events.append(MarkerEvent(
                        startSample: index * hop,
                        set: set,
                        power: powers[peak],
                        snrDB: snr
                    ))
                    index = peak + 1
                } else {
                    index += 1
                }
            }
            perSet.append(events)
        }

        let combined = perSet.flatMap { $0 }.sorted { $0.startSample < $1.startSample }
        var merged: [MarkerEvent] = []
        for event in combined {
            if let last = merged.last, event.startSample - last.startSample < ScanProtocol.markerSamples {
                if event.power > last.power {
                    merged[merged.count - 1] = event
                }
            } else {
                merged.append(event)
            }
        }

        // 数据段里也可能有标记频率的能量；一帧之内不可能出现两个真正的标记音。
        // 用上一帧的完整长度（标记 + 保护 + 数据 + 尾静音）过滤帧内伪事件。
        var filtered: [MarkerEvent] = []
        for event in merged {
            if let last = filtered.last {
                let minimumNext = last.startSample + ScanProtocol.frameSamples(for: last.set)
                if event.startSample < minimumNext { continue }
            }
            filtered.append(event)
        }
        return filtered
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
        let offsets = [0, -48, 48, -96, 96, -144, 144, -192, 192, -240, 240]
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
