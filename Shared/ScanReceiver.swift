import Foundation

/// 实时扫描接收器：滚动缓冲里做 Naiser3 前导互相关，帧到齐后立即解调。
/// 不保存整段录音做后处理；结果在收到每个包时通过 onUpdate 推给 UI。
final class ScanReceiver {
    var onUpdate: ((ScanAnalysis) -> Void)?
    var onLog: ((String) -> Void)?

    private struct PendingPreamble {
        var peakAbs: Int
        var score: Float
    }

    private let config: ScanRunConfig
    private let sets: [SpectralSet]
    private let packetsPerSet: Int
    private let startedAt: Date
    private let maxDataSamples: Int
    private let preambleLength = WatercommsPhy.preamble.count
    private let seek = WatercommsPhy.gap
    private let correlationThreshold: Float = 0.4
    private let minPeakDistance = 8_000
    private let timingOffsets = [0, -4, 4, -8, 8, -16, 16, -32, 32, -48, 48, -67, 67]

    private let lock = NSLock()
    private var window: [Float] = []
    private var windowStart = 0
    private var scanAbs = 0
    private var sampleRate: Double = 48_000
    private var pending: [PendingPreamble] = []
    private var results: [String: ScanPacketResult] = [:]
    private var corruptEvents = 0
    private var expectedSetIndex = 0
    private let cancelLock = NSLock()
    private var canceled = false

    init(config: ScanRunConfig, startedAt: Date) {
        let normalized = config.normalized
        self.config = normalized
        self.sets = normalized.activeSets
        self.packetsPerSet = max(1, min(200, normalized.packetsPerSet))
        self.startedAt = startedAt
        self.maxDataSamples = (normalized.activeSets.map { set -> Int in
            let plan = ScanProtocol.plan(for: set)
            return plan.packetSamples - plan.preamble.count - plan.gap
        }.max() ?? 0) + 128
    }

    /// 用户停止后，队列里尚未处理的音频块直接丢弃，不再做标记/解调。
    func cancel() {
        cancelLock.lock()
        canceled = true
        cancelLock.unlock()
    }

    private var isCanceled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return canceled
    }

    func ingest(_ samples: [Float], at date: Date, sampleRate: Double) {
        var logs: [String] = []
        var update: ScanAnalysis?

        guard !isCanceled else { return }
        lock.lock()
        guard !isCanceled else {
            lock.unlock()
            return
        }
        if self.sampleRate == 0 { self.sampleRate = sampleRate }
        window.append(contentsOf: samples)
        detectPreambles(logs: &logs)
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
        let wasCanceled = isCanceled
        if !wasCanceled {
            _ = processPending(logs: &logs)
        }
        let analysis = build(finishedAt: Date())
        lock.unlock()
        for line in logs { onLog?(line) }
        return analysis
    }

    // MARK: - 前导

    private func detectPreambles(logs: inout [String]) {
        guard preambleLength > 0 else { return }
        let maxNewLags = 16_384
        while !isCanceled {
            let bufferEnd = windowStart + window.count
            let newestLag = bufferEnd - preambleLength
            guard newestLag >= scanAbs else { return }

            let scoreStart = max(windowStart, scanAbs - seek)
            let newLags = min(maxNewLags, newestLag - scanAbs + 1)
            let scoreEnd = scanAbs + newLags
            let localStart = scoreStart - windowStart
            let localEnd = scoreEnd - windowStart + preambleLength - 1
            guard localStart >= 0, localEnd <= window.count, localEnd > localStart else { return }

            let region = Array(window[localStart..<localEnd])
            let scores = WatercommsPhy.preambleScores(in: region)
            guard scores.count == scoreEnd - scoreStart else {
                scanAbs = scoreEnd
                continue
            }
            let peaks = WatercommsPhy.preamblePeaks(
                scores: scores,
                threshold: correlationThreshold,
                minDistance: minPeakDistance
            )
            for peak in peaks {
                let absLag = scoreStart + peak.index
                guard absLag >= scanAbs, absLag < scoreEnd else { continue }
                let seekLag = scoreStart + WatercommsPhy.seekback(scores: scores, peak: peak.index, seek: seek)
                let localSeek = seekLag - windowStart
                let adjusted = windowStart + WatercommsPhy.channelLookbackStart(samples: window, seekbackLag: localSeek)
                if pending.contains(where: { abs($0.peakAbs - adjusted) < minPeakDistance }) { continue }
                pending.append(PendingPreamble(peakAbs: adjusted, score: peak.score))
                logs.append(String(
                    format: "前导 样本=%d 相关=%.3f 起点=%d",
                    locale: Locale(identifier: "en_US_POSIX"),
                    absLag, peak.score, adjusted
                ))
            }
            scanAbs = scoreEnd
        }
    }

    // MARK: - 数据帧

    private func processPending(logs: inout [String]) -> Bool {
        var remaining: [PendingPreamble] = []
        var changed = false
        for preamble in pending {
            let dataStart = preamble.peakAbs + ScanProtocol.dataStartOffset
            let requiredEnd = dataStart + maxDataSamples
            guard requiredEnd <= windowStart + window.count else {
                remaining.append(preamble)
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
                    markerSNRDB: Double(preamble.score),
                    airtimeMs: hit.set.airtimeMs,
                    frameSample: preamble.peakAbs,
                    timestamp: startedAt.addingTimeInterval(Double(preamble.peakAbs) / sampleRate)
                )
                results[key] = result
                if let index = sets.firstIndex(where: { $0.id == hit.set.id }) {
                    let next = hit.packetIndex + 1
                    expectedSetIndex = next < packetsPerSet ? index : (index + 1) % sets.count
                }
                logs.append(String(
                    format: "事件 集合=%@ 样本=%d 前导相关=%.3f 解出=%@ 包=%d 通过=是 数据SNR=%.1fdB 偏移=%d",
                    locale: Locale(identifier: "en_US_POSIX"),
                    hit.set.id, preamble.peakAbs, preamble.score,
                    ScanPayload.hex(hit.word), hit.packetIndex, hit.snrDB, hit.offset
                ))
                changed = true
            } else {
                corruptEvents += 1
                var diagnostics = ""
                let local = dataStart - windowStart
                if local >= 0, local < window.count {
                    let end = min(window.count, local + maxDataSamples)
                    let slice = window[local..<end]
                    let frequencies = [1_000, 2_000, 4_000, 6_000, 8_000]
                    let powers = frequencies.map { frequency in
                        String(format: "%.3g", Goertzel.power(samples: slice, sampleRate: sampleRate, frequency: Double(frequency)))
                    }
                    diagnostics = " 数据窗口=\(local)..\(end) 能量1k/2k/4k/6k/8k=\(powers.joined(separator: "/"))"
                }
                logs.append(String(
                    format: "未匹配 样本=%d 前导相关=%.3f 期望=%@ 候选=%d 偏移数=%d%@",
                    locale: Locale(identifier: "en_US_POSIX"),
                    preamble.peakAbs, preamble.score,
                    sets.isEmpty ? "none" : sets[expectedSetIndex].id,
                    sets.count, timingOffsets.count, diagnostics
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
            let symbolCount = plan.packetSamples - plan.preamble.count - plan.gap
            for offset in timingOffsets {
                let startAbs = dataStartAbs + offset
                let local = startAbs - windowStart
                guard local >= 0, local + symbolCount <= window.count else { continue }
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
        // 保留最近 3 秒。watercomms 一帧大约 0.3–0.5 秒，前导起点必须留到数据符号到齐。
        let keepFrom = windowStart + window.count - 144_000
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

}
