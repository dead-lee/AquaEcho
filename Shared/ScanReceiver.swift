import Foundation

/// 实时扫描接收器：按音频块滚动检测 400 Hz 标记音，标记后等数据帧到齐立即解调。
/// 不保存整段录音做后处理；结果在收到每个包时通过 onUpdate 推给 UI。
final class ScanReceiver {
    var onUpdate: ((ScanAnalysis) -> Void)?
    var onLog: ((String) -> Void)?

    private struct PendingMarker {
        var peakAbs: Int
        var snrDB: Double
    }

    private let config: ScanRunConfig
    private let sets: [SpectralSet]
    private let packetsPerSet: Int
    private let startedAt: Date
    private let maxDataSamples: Int
    private let markerWindow = ScanProtocol.markerSamples
    private let hop = 240
    private let offsets = [0, -48, 48, -96, 96, -144, 144, -192, 192, -240, 240, -288, 288, -336, 336, -384, 384, -432, 432, -480, 480]

    private let lock = NSLock()
    private var window: [Float] = []
    private var windowStart = 0
    private var scanAbs = 0
    private var sampleRate: Double = 48_000
    private var noiseHistory: [Double] = []
    private var inRun = false
    private var runPeakAbs = 0
    private var runPeakPower = 0.0
    private var runNoise = 1e-9
    private var pending: [PendingMarker] = []
    private var results: [String: ScanPacketResult] = [:]
    private var corruptEvents = 0
    private var expectedSetIndex = 0

    init(config: ScanRunConfig, startedAt: Date) {
        let normalized = config.normalized
        self.config = normalized
        self.sets = normalized.activeSets
        self.packetsPerSet = max(1, min(200, normalized.packetsPerSet))
        self.startedAt = startedAt
        self.maxDataSamples = (normalized.activeSets.map { ScanProtocol.plan(for: $0).packetSamples }.max() ?? 0) + 480
    }

    func ingest(_ samples: [Float], at date: Date, sampleRate: Double) {
        var logs: [String] = []
        var update: ScanAnalysis?

        lock.lock()
        if self.sampleRate == 0 { self.sampleRate = sampleRate }
        window.append(contentsOf: samples)
        detectMarkers(logs: &logs)
        if processPending(logs: &logs) {
            update = build(finishedAt: date)
        }
        trim()
        lock.unlock()

        for line in logs { onLog?(line) }
        if let update { onUpdate?(update) }
    }

    func finish() -> ScanAnalysis {
        var logs: [String] = []
        lock.lock()
        closeRun(logs: &logs)
        _ = processPending(logs: &logs)
        let analysis = build(finishedAt: Date())
        lock.unlock()
        for line in logs { onLog?(line) }
        return analysis
    }

    // MARK: - 标记音

    private func detectMarkers(logs: inout [String]) {
        guard markerWindow > 0, hop > 0 else { return }
        while scanAbs + markerWindow <= windowStart + window.count {
            let local = scanAbs - windowStart
            let power = Goertzel.power(
                samples: window[local..<(local + markerWindow)],
                sampleRate: sampleRate,
                frequency: ScanProtocol.markerHz
            )
            noiseHistory.append(power)
            if noiseHistory.count > 400 { noiseHistory.removeFirst(noiseHistory.count - 400) }
            let noise = percentile(noiseHistory, 0.20)
            let threshold = max(noise * 300, 1e-6)

            if power > threshold {
                if !inRun {
                    inRun = true
                    runPeakAbs = scanAbs
                    runPeakPower = power
                    runNoise = max(noise, 1e-20)
                } else if power > runPeakPower {
                    runPeakAbs = scanAbs
                    runPeakPower = power
                }
            } else if inRun {
                closeRun(logs: &logs)
            }
            scanAbs += hop
        }
    }

    private func closeRun(logs: inout [String]) {
        guard inRun else { return }
        inRun = false
        let snr = 10 * log10(max(runPeakPower, 1e-20) / max(runNoise, 1e-20))
        pending.append(PendingMarker(peakAbs: runPeakAbs, snrDB: snr))
        logs.append(String(
            format: "标记 样本=%d SNR=%.1fdB",
            locale: Locale(identifier: "en_US_POSIX"),
            runPeakAbs, snr
        ))
    }

    // MARK: - 数据帧

    private func processPending(logs: inout [String]) -> Bool {
        var remaining: [PendingMarker] = []
        var changed = false
        for marker in pending {
            let dataStart = marker.peakAbs + ScanProtocol.dataStartOffset
            let requiredEnd = dataStart + maxDataSamples
            guard requiredEnd <= windowStart + window.count else {
                remaining.append(marker)
                continue
            }
            if let hit = decode(dataStartAbs: dataStart) {
                let key = "\(hit.set.id)#\(hit.packetIndex)"
                let result = ScanPacketResult(
                    setID: hit.set.id,
                    setTitle: hit.set.title,
                    carrierCount: hit.set.carrierCount,
                    packetIndex: hit.packetIndex,
                    expectedHex: ScanPayload.hex(ScanPayload.make(setID: hit.set.id, packetIndex: hit.packetIndex)),
                    decodedHex: ScanPayload.hex(hit.word),
                    passed: true,
                    detected: true,
                    snrDB: hit.snrDB,
                    markerSNRDB: marker.snrDB,
                    airtimeMs: hit.set.airtimeMs,
                    frameSample: marker.peakAbs,
                    timestamp: startedAt.addingTimeInterval(Double(marker.peakAbs) / sampleRate)
                )
                results[key] = result
                if let index = sets.firstIndex(where: { $0.id == hit.set.id }) {
                    let next = hit.packetIndex + 1
                    expectedSetIndex = next < packetsPerSet ? index : (index + 1) % sets.count
                }
                logs.append(String(
                    format: "事件 集合=%@ 样本=%d 标记SNR=%.1fdB 解出=%@ 包=%d 通过=是 数据SNR=%.1fdB 偏移=%d",
                    locale: Locale(identifier: "en_US_POSIX"),
                    hit.set.id, marker.peakAbs, marker.snrDB,
                    ScanPayload.hex(hit.word), hit.packetIndex, hit.snrDB, hit.offset
                ))
                changed = true
            } else {
                corruptEvents += 1
                logs.append(String(
                    format: "未匹配 样本=%d 标记SNR=%.1fdB",
                    locale: Locale(identifier: "en_US_POSIX"),
                    marker.peakAbs, marker.snrDB
                ))
            }
        }
        pending = remaining
        return changed
    }

    private struct Hit {
        var set: SpectralSet
        var word: UInt64
        var packetIndex: Int
        var snrDB: Double
        var offset: Int
    }

    private func decode(dataStartAbs: Int) -> Hit? {
        var candidates = [sets[expectedSetIndex]]
        for (index, set) in sets.enumerated() where index != expectedSetIndex {
            candidates.append(set)
        }
        for set in candidates {
            let plan = ScanProtocol.plan(for: set)
            for offset in offsets {
                let startAbs = dataStartAbs + offset
                let local = startAbs - windowStart
                guard local >= 0, local + plan.packetSamples <= window.count else { continue }
                guard let demod = OFDMModem.demodulateFrequencyOnly(window: window, symbolStart: local, plan: plan) else { continue }
                let decoded = ConvolutionalCode.decode(demod.bits)
                guard decoded.count == PacketLayout.bitCount else { continue }
                let word = word(from: decoded)
                let setCode = ScanPayload.setCode(of: word)
                let packet = ScanPayload.packetIndex(of: word)
                guard setCode == set.code, packet >= 0, packet < packetsPerSet else { continue }
                let expected = ScanPayload.make(setCode: setCode, packetIndex: packet)
                guard word == expected else { continue }
                let snr = demod.readings.isEmpty ? 0 : demod.readings.reduce(0) { $0 + $1.snrDB } / Double(demod.readings.count)
                return Hit(set: set, word: word, packetIndex: packet, snrDB: snr, offset: offset)
            }
        }
        return nil
    }

    private func word(from bits: [Bool]) -> UInt64 {
        var word: UInt64 = 0
        for bit in bits {
            word = (word << 1) | (bit ? 1 : 0)
        }
        return word
    }

    // MARK: - 缓冲

    private func trim() {
        // 保留最近 2 秒，足够覆盖最大帧和待解码标记。
        let keepFrom = windowStart + window.count - 96_000
        if keepFrom > windowStart {
            let remove = min(keepFrom - windowStart, window.count)
            window.removeFirst(remove)
            windowStart += remove
        }
        if scanAbs < windowStart { scanAbs = windowStart }
    }

    private func build(finishedAt: Date) -> ScanAnalysis {
        ScanResultBuilder.build(
            config: config,
            results: results,
            startedAt: startedAt,
            finishedAt: finishedAt,
            sampleRate: sampleRate,
            corruptEvents: corruptEvents
        )
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }
}
