import Foundation

/// 实时扫描接收器：每个集合用自己频段的前导做互相关。
/// 8000 样本内按相关从高到低解调，64 bit 对上就不再试下一条。
/// 不保存整段录音做后处理；结果在收到每个包时通过 onUpdate 推给 UI。
final class ScanReceiver {
    var onUpdate: ((ScanAnalysis) -> Void)?
    var onLog: ((String) -> Void)?

    /// 同一段 8000 样本里的候选，按相关从高到低。信道回看到解调时再做。
    private struct CandidatePeak {
        var setIndex: Int
        var absLag: Int
        var seekLag: Int
        var score: Float
    }

    private struct PendingGroup {
        var peaks: [CandidatePeak]
    }

    private struct PendingPreamble {
        var setIndex: Int
        var peakAbs: Int
        var seekAbs: Int
        var score: Float
    }

    private let config: ScanRunConfig
    private let sets: [SpectralSet]
    private let packetsPerSet: Int
    private let startedAt: Date
    private let maxDataSamples: Int
    private let preambleLength = WatercommsPhy.preamble.count
    private let seek = WatercommsPhy.gap
    private let correlationThreshold: Float = 0.20
    private let minPeakDistance = 8_000
    /// 对齐良好的包落在 ±Cp。手持第二段录音的符号起点在相关峰前大约 100 点，要单独往前搜。
    private let timingOffsets = [0, -4, 4, -8, 8, -16, 16, -32, 32, -48, 48, -67, 67]
    private let earlyTimingOffsets = Array(stride(from: -160, through: -80, by: 16))

    private let lock = NSLock()
    private var window: [Float] = []
    private var windowStart = 0
    private var scanAbs = 0
    private var sampleRate: Double = 48_000
    private var pending: [PendingGroup] = []
    private var results: [String: ScanPacketResult] = [:]
    private var corruptEvents = 0
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
            let delay = WatercommsPhy.syncFilterDelay
            var found: [CandidatePeak] = []
            for (setIndex, set) in sets.enumerated() {
                let band = WatercommsPhy.syncBand(for: set)
                let kernel = WatercommsPhy.preamble(for: set)
                let filtered = WatercommsPhy.bandpassForSync(region, lowHz: band.lowHz, highHz: band.highHz)
                let scores = WatercommsPhy.preambleScores(in: filtered, kernel: kernel, cacheKey: set.id)
                guard scores.count == scoreEnd - scoreStart else { continue }
                let peaks = WatercommsPhy.preamblePeaks(
                    scores: scores,
                    threshold: correlationThreshold,
                    minDistance: minPeakDistance
                )
                for peak in peaks {
                    let rawIndex = peak.index + delay
                    let absLag = scoreStart + rawIndex
                    guard absLag >= scanAbs, absLag < scoreEnd else { continue }
                    let seekIndex = WatercommsPhy.seekback(scores: scores, peak: peak.index, seek: seek) + delay
                    let seekLag = scoreStart + max(0, seekIndex)
                    found.append(CandidatePeak(setIndex: setIndex, absLag: absLag, seekLag: seekLag, score: peak.score))
                }
            }
            // 手表依次发送，8000 点到不了下一包。同一段里的峰留在一组，解调时从高到低试。
            found.sort { $0.score > $1.score }
            for peak in found {
                if let index = pending.firstIndex(where: { group in
                    group.peaks.contains { abs($0.seekLag - peak.seekLag) < minPeakDistance }
                }) {
                    let wasBest = pending[index].peaks.first
                    if let same = pending[index].peaks.firstIndex(where: { $0.setIndex == peak.setIndex }) {
                        if peak.score > pending[index].peaks[same].score {
                            pending[index].peaks[same] = peak
                        }
                    } else {
                        pending[index].peaks.append(peak)
                    }
                    pending[index].peaks.sort { $0.score > $1.score }
                    if let best = pending[index].peaks.first,
                       best.setIndex != wasBest?.setIndex || best.score > (wasBest?.score ?? 0) {
                        logs.append(preambleLog(set: sets[best.setIndex], absLag: best.absLag, score: best.score, looked: best.seekLag))
                    }
                    continue
                }
                pending.append(PendingGroup(peaks: [peak]))
                logs.append(preambleLog(set: sets[peak.setIndex], absLag: peak.absLag, score: peak.score, looked: peak.seekLag))
            }
            scanAbs = scoreEnd
        }
    }

    private func preambleLog(set: SpectralSet, absLag: Int, score: Float, looked: Int) -> String {
        String(
            format: "前导 集合=%@ 样本=%d 相关=%.3f 起点=%d",
            locale: Locale(identifier: "en_US_POSIX"),
            set.id, absLag, score, looked
        )
    }

    // MARK: - 数据帧

    private func processPending(logs: inout [String]) -> Bool {
        var remaining: [PendingGroup] = []
        var changed = false
        for group in pending {
            guard let anchor = group.peaks.map(\.seekLag).max() else { continue }
            // 回看最多把起点往后挪几百点，数据窗按最晚的候选留余量。
            let latest = anchor + 400 + (timingOffsets.max() ?? 0)
            let dataStart = latest + ScanProtocol.dataStartOffset
            let requiredEnd = dataStart + maxDataSamples
            guard requiredEnd <= windowStart + window.count else {
                remaining.append(group)
                continue
            }
            var matched = false
            var bestAttempt: PendingPreamble?
            for peak in group.peaks {
                let attempt = aligned(peak)
                if bestAttempt == nil { bestAttempt = attempt }
                guard let hit = decode(preamble: attempt) else { continue }
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
                    markerSNRDB: Double(attempt.score),
                    airtimeMs: hit.set.airtimeMs,
                    frameSample: attempt.peakAbs,
                    timestamp: startedAt.addingTimeInterval(Double(attempt.peakAbs) / sampleRate)
                )
                results[key] = result
                logs.append(String(
                    format: "事件 集合=%@ 样本=%d 前导相关=%.3f 解出=%@ 包=%d 通过=是 数据SNR=%.1fdB 偏移=%d",
                    locale: Locale(identifier: "en_US_POSIX"),
                    hit.set.id, attempt.peakAbs, attempt.score,
                    ScanPayload.hex(hit.word), hit.packetIndex, hit.snrDB, hit.offset
                ))
                changed = true
                matched = true
                break
            }
            if !matched, let attempt = bestAttempt {
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
                    format: "未匹配 集合=%@ 样本=%d 前导相关=%.3f 偏移数=%d%@",
                    locale: Locale(identifier: "en_US_POSIX"),
                    sets[attempt.setIndex].id, attempt.peakAbs, attempt.score,
                    timingOffsets.count, diagnostics
                ))
            }
        }
        pending = remaining
        return changed
    }

    private func aligned(_ peak: CandidatePeak) -> PendingPreamble {
        let set = sets[peak.setIndex]
        let kernel = WatercommsPhy.preamble(for: set)
        let localSeek = peak.seekLag - windowStart
        let looked = windowStart + WatercommsPhy.channelLookbackStart(
            samples: window,
            seekbackLag: localSeek,
            preamble: kernel,
            lowHz: set.lowHz,
            highHz: set.highHz
        )
        return PendingPreamble(setIndex: peak.setIndex, peakAbs: looked, seekAbs: peak.seekLag, score: peak.score)
    }

    private struct Hit {
        var set: SpectralSet
        var word: UInt64
        var packetIndex: Int
        var snrDB: Double
        var offset: Int
    }

    private func decode(preamble: PendingPreamble) -> Hit? {
        let set = sets[preamble.setIndex]
        let plan = ScanProtocol.plan(for: set)
        let symbolCount = plan.packetSamples - plan.preamble.count - plan.gap
        var bases = [preamble.peakAbs]
        if preamble.seekAbs != preamble.peakAbs {
            bases.append(preamble.seekAbs)
        }
        for base in bases {
            let needsEarly = preamble.score < 0.5 && base == preamble.seekAbs
            let offsets = needsEarly ? earlyTimingOffsets + timingOffsets : timingOffsets
            for offset in offsets {
                let startAbs = base + ScanProtocol.dataStartOffset + offset
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
