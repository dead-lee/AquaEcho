import Foundation

/// 实时扫描接收器。扫描配置已经约定每个包的频率。
/// 当前包只相关这一条前导，只在 seekback 起点解调一次。失败不改频段重试。
final class ScanReceiver {
    var onUpdate: ((ScanAnalysis) -> Void)?
    var onLog: ((String) -> Void)?

    /// 当前约定集合的一条前导。8000 样本内只保留相关更高的峰。
    private struct CandidatePeak {
        var setIndex: Int
        var absLag: Int
        var seekLag: Int
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

    private let lock = NSLock()
    private var window: [Float] = []
    private var windowStart = 0
    private var scanAbs = 0
    private var sampleRate: Double = 48_000
    /// 扫描配置里的当前位置。只听 `sets[setCursor]` 的前导。
    private var setCursor = 0
    private var nextPacket = 0
    /// 旁瓣先到时先按住，8000 样本内若出现更高的峰就换掉，再解调一次。
    private var held: CandidatePeak?
    private var committed: [CandidatePeak] = []
    private var lastEventAbs: Int?
    /// 已经收下的那一包播完之前，后面的峰是旁瓣或正文，不是下一包。用那一包自己的帧长。
    private var blockedUntil = 0
    /// 手表倒计时结束前的峰是入水、拍水的假峰，不算包。
    private var ignoredBefore = 0
    private var scheduleStarted = false
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
            ScanProtocol.frameSamples(for: set) - ScanProtocol.preambleSamples - ScanProtocol.chirpGap
        }.max() ?? 0) + 128
    }

    /// 用户停止后，队列里尚未处理的音频块直接丢弃，不再做标记/解调。
    func cancel() {
        cancelLock.lock()
        canceled = true
        cancelLock.unlock()
    }

    /// 从已收到音频的末尾起，`seconds` 秒内的前导峰只记日志，不解调、不推进约定顺序。
    func ignorePreambles(forSeconds seconds: Double) {
        lock.lock()
        let rate = sampleRate > 0 ? sampleRate : 48_000
        ignoredBefore = windowStart + window.count + Int((max(0, seconds) * rate).rounded())
        let until = ignoredBefore
        lock.unlock()
        onLog?("倒计时门限 忽略样本<\(until)")
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
        if processPending(logs: &logs, flush: false) {
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
            _ = processPending(logs: &logs, flush: true)
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

            guard let setIndex = currentSetIndex() else { return }
            let set = sets[setIndex]
            let region = Array(window[localStart..<localEnd])
            let delay = WatercommsPhy.syncFilterDelay
            let band = WatercommsPhy.syncBand(for: set)
            let kernel = WatercommsPhy.preamble(for: set)
            let filtered = WatercommsPhy.bandpassForSync(region, lowHz: band.lowHz, highHz: band.highHz)
            let scores = WatercommsPhy.preambleScores(in: filtered, kernel: kernel, cacheKey: set.id)
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
                let rawIndex = peak.index + delay
                let absLag = scoreStart + rawIndex
                guard absLag >= scanAbs, absLag < scoreEnd else { continue }
                let seekIndex = WatercommsPhy.seekback(scores: scores, peak: peak.index, seek: seek) + delay
                let seekLag = scoreStart + max(0, seekIndex)
                consider(CandidatePeak(setIndex: setIndex, absLag: absLag, seekLag: seekLag, score: peak.score), logs: &logs)
            }
            if let held, scanAbs >= held.seekLag + minPeakDistance {
                commit(held)
                self.held = nil
            }
            scanAbs = scoreEnd
        }
    }

    private func currentSetIndex() -> Int? {
        guard setCursor < sets.count, nextPacket < packetsPerSet else { return nil }
        return setCursor
    }

    /// 同一条前导的旁瓣和主峰相距约 7200 点。先按住，窗口里出现更高的峰再换。
    /// 这一帧结束前出现的峰是旁瓣，不是下一包。
    private func consider(_ peak: CandidatePeak, logs: inout [String]) {
        if peak.absLag < ignoredBefore {
            logs.append(String(
                format: "倒计时内忽略 集合=%@ 样本=%d 相关=%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                sets[peak.setIndex].id, peak.absLag, peak.score
            ))
            return
        }
        if tooEarly(peak) { return }
        if let held, abs(peak.seekLag - held.seekLag) < minPeakDistance {
            guard peak.score > held.score else { return }
            self.held = peak
            logs.append(preambleLog(set: sets[peak.setIndex], absLag: peak.absLag, score: peak.score, looked: peak.seekLag))
            return
        }
        if let held {
            commit(held)
            self.held = nil
        }
        if tooEarly(peak) { return }
        held = peak
        logs.append(preambleLog(set: sets[peak.setIndex], absLag: peak.absLag, score: peak.score, looked: peak.seekLag))
    }

    private func commit(_ peak: CandidatePeak) {
        committed.append(peak)
        let end = peak.absLag + ScanProtocol.frameSamples(for: sets[peak.setIndex])
        if end > blockedUntil { blockedUntil = end }
    }

    private func tooEarly(_ peak: CandidatePeak) -> Bool {
        peak.absLag < blockedUntil
    }

    private func preambleLog(set: SpectralSet, absLag: Int, score: Float, looked: Int) -> String {
        String(
            format: "前导 集合=%@ 样本=%d 相关=%.3f 起点=%d",
            locale: Locale(identifier: "en_US_POSIX"),
            set.id, absLag, score, looked
        )
    }

    // MARK: - 数据帧

    private func processPending(logs: inout [String], flush: Bool) -> Bool {
        if flush, let held {
            committed.append(held)
            self.held = nil
        }
        var changed = false
        var waiting: [CandidatePeak] = []
        for peak in committed {
            guard peak.setIndex == setCursor, peakReady(peak) else {
                if peak.setIndex == setCursor {
                    waiting.append(peak)
                }
                continue
            }
            if let hit = decode(peak) {
                record(hit, attempt: peak, logs: &logs)
                changed = true
                note(packetIndex: hit.packetIndex, at: peak.absLag)
            } else {
                corruptEvents += 1
                logs.append(failureLog(peak))
                noteFailure(at: peak.absLag)
            }
        }
        committed = waiting
        if skipUnheard(logs: &logs) {
            changed = true
        }
        return changed
    }

    private func record(_ hit: Hit, attempt: CandidatePeak, logs: inout [String]) {
        let key = "\(hit.set.id)#\(hit.packetIndex)"
        results[key] = ScanPacketResult(
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
            frameSample: attempt.seekLag,
            timestamp: startedAt.addingTimeInterval(Double(attempt.seekLag) / sampleRate)
        )
        logs.append(String(
            format: "事件 集合=%@ 样本=%d 前导相关=%.3f 解出=%@ 包=%d 通过=是 数据SNR=%.1fdB",
            locale: Locale(identifier: "en_US_POSIX"),
            hit.set.id, attempt.seekLag, attempt.score,
            ScanPayload.hex(hit.word), hit.packetIndex, hit.snrDB
        ))
    }

    private func failureLog(_ attempt: CandidatePeak) -> String {
        var diagnostics = ""
        let payload = ScanProtocol.frameSamples(for: sets[attempt.setIndex]) - ScanProtocol.preambleSamples - ScanProtocol.chirpGap
        let dataStart = attempt.seekLag + ScanProtocol.dataStartOffset
        let local = dataStart - windowStart
        if local >= 0, local < window.count {
            let end = min(window.count, local + payload)
            let slice = window[local..<end]
            let frequencies = [1_000, 2_000, 4_000, 6_000, 8_000]
            let powers = frequencies.map { frequency in
                String(format: "%.3g", Goertzel.power(samples: slice, sampleRate: sampleRate, frequency: Double(frequency)))
            }
            diagnostics = " 数据窗口=\(local)..\(end) 能量1k/2k/4k/6k/8k=\(powers.joined(separator: "/"))"
        }
        return String(
            format: "未匹配 集合=%@ 样本=%d 前导相关=%.3f%@",
            locale: Locale(identifier: "en_US_POSIX"),
            sets[attempt.setIndex].id, attempt.seekLag, attempt.score, diagnostics
        )
    }

    /// 解出的包序号就是这一包。中间没听到的序号留空，不拿别的频率去补。
    private func note(packetIndex: Int, at sample: Int) {
        scheduleStarted = true
        lastEventAbs = sample
        nextPacket = max(nextPacket, packetIndex + 1)
        if nextPacket >= packetsPerSet {
            advanceSchedule(from: sample)
        }
    }

    private func noteFailure(at sample: Int) {
        scheduleStarted = true
        lastEventAbs = sample
        nextPacket += 1
        if nextPacket >= packetsPerSet {
            advanceSchedule(from: sample)
        }
    }

    private func advanceSchedule(from sample: Int) {
        guard setCursor < sets.count else { return }
        let finished = sets[setCursor]
        setCursor += 1
        nextPacket = 0
        let resume = sample + ScanProtocol.frameSamples(for: finished)
        if resume < scanAbs {
            scanAbs = max(windowStart, resume)
        }
    }

    /// 这一包的前导一直没出现。听过本集合之后，空档超过两帧就记缺失并转到约定的下一包。
    private func skipUnheard(logs: inout [String]) -> Bool {
        guard scheduleStarted, held == nil, committed.isEmpty, setCursor < sets.count, var cursor = lastEventAbs else { return false }
        let set = sets[setCursor]
        let gap = ScanProtocol.frameSamples(for: set) * 2
        let audioEnd = windowStart + window.count
        var skipped = false
        while nextPacket < packetsPerSet, audioEnd > cursor + gap {
            logs.append(String(
                format: "未听到 集合=%@ 包=%d",
                locale: Locale(identifier: "en_US_POSIX"),
                set.id, nextPacket
            ))
            nextPacket += 1
            cursor += gap
            lastEventAbs = cursor
            skipped = true
            if nextPacket >= packetsPerSet {
                advanceSchedule(from: cursor)
                break
            }
        }
        return skipped
    }

    private func peakReady(_ peak: CandidatePeak) -> Bool {
        let payload = ScanProtocol.frameSamples(for: sets[peak.setIndex]) - ScanProtocol.preambleSamples - ScanProtocol.chirpGap
        let requiredEnd = peak.seekLag + ScanProtocol.dataStartOffset + payload
        return requiredEnd <= windowStart + window.count
    }

    private struct Hit {
        var set: SpectralSet
        var word: UInt64
        var packetIndex: Int
        var snrDB: Double
    }

    /// 只在 seekback 这一个起点解调。跳过 Cp 后做符号频谱。
    private func decode(_ peak: CandidatePeak) -> Hit? {
        let set = sets[peak.setIndex]
        let symbolCount = ScanProtocol.frameSamples(for: set) - ScanProtocol.preambleSamples - ScanProtocol.chirpGap
        let local = peak.seekLag + ScanProtocol.dataStartOffset - windowStart
        guard local >= 0, local + symbolCount <= window.count else { return nil }
        let plan = ScanProtocol.plan(for: set)
        guard let demod = OFDMModem.demodulateFrequencyOnly(window: window, symbolStart: local, plan: plan) else { return nil }
        let snr = demod.readings.isEmpty ? 0 : demod.readings.reduce(0) { $0 + $1.snrDB } / Double(demod.readings.count)
        let decoded = ConvolutionalCode.decode(demod.soft)
        guard decoded.count == PacketLayout.bitCount else { return nil }
        let word = word(from: decoded)
        let setCode = ScanPayload.setCode(of: word)
        let packet = ScanPayload.packetIndex(of: word)
        guard setCode == set.code, packet >= 0, packet < packetsPerSet else { return nil }
        let expected = ScanPayload.make(setCode: setCode, packetIndex: packet)
        guard word == expected else { return nil }
        return Hit(set: set, word: word, packetIndex: packet, snrDB: snr)
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
        // 缓冲盖住最长的一帧，前导才不会在数据到齐前被裁掉。
        let keepCount = max(144_000, maxDataSamples + preambleLength + seek + 24_000)
        let keepFrom = windowStart + window.count - keepCount
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
