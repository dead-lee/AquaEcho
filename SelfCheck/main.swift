import Foundation

var failures: [String] = []

func expect(_ condition: Bool, _ message: String) {
    if !condition {
        failures.append(message)
        fputs("FAIL \(message)\n", stderr)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        failures.append("\(message): got \(actual), expected \(expected)")
        fputs("FAIL \(message): got \(actual), expected \(expected)\n", stderr)
    }
}

// MARK: - 评分边界

expectEqual(ChannelScore.snrPoints(25), 40, "snr 25")
expectEqual(ChannelScore.snrPoints(24.999), 32, "snr just under 25")
expectEqual(ChannelScore.snrPoints(20), 32, "snr 20")
expectEqual(ChannelScore.snrPoints(15), 24, "snr 15")
expectEqual(ChannelScore.snrPoints(10), 16, "snr 10")
expectEqual(ChannelScore.snrPoints(5), 8, "snr 5")
expectEqual(ChannelScore.snrPoints(4.999), 0, "snr under 5")

expectEqual(ChannelScore.separationPoints(ratioDB: 6), 20, "ratio 6")
expectEqual(ChannelScore.separationPoints(ratioDB: 5.999), 12, "ratio just under 6")
expectEqual(ChannelScore.separationPoints(ratioDB: 3), 12, "ratio 3")
expectEqual(ChannelScore.separationPoints(ratioDB: 1), 6, "ratio 1")
expectEqual(ChannelScore.separationPoints(ratioDB: 0.99), 0, "ratio under 1")

expectEqual(ChannelScore.passRatePoints(passed: 5, total: 5), 40, "pass 100%")
expectEqual(ChannelScore.passRatePoints(passed: 4, total: 5), 32, "pass 80%")
expectEqual(ChannelScore.passRatePoints(passed: 3, total: 5), 24, "pass 60%")
expectEqual(ChannelScore.passRatePoints(passed: 2, total: 5), 16, "pass 40%")
expectEqual(ChannelScore.passRatePoints(passed: 1, total: 5), 8, "pass 20%")
expectEqual(ChannelScore.passRatePoints(passed: 0, total: 5), 0, "pass 0%")
expectEqual(ChannelScore.passRatePoints(passed: 5, total: 6), 32, "pass 5/6")
expectEqual(ChannelScore.passRatePoints(passed: 4, total: 6), 24, "pass 4/6")
expectEqual(ChannelScore.passRatePoints(passed: 1, total: 6), 0, "pass under 20%")

let total = ChannelScore.breakdown(snrDB: 30, ratioDB: 8, passedCount: 3, totalCount: 3)
expectEqual(total.snr, 40, "breakdown snr")
expectEqual(total.separation, 20, "breakdown separation")
expectEqual(total.passRate, 40, "breakdown pass rate")
expectEqual(total.total, 100, "breakdown total")

// MARK: - 频率对

var sweep = TestConfig()
let pairs = sweep.plannedPairs()
expect(pairs.count >= 8, "default sweep should cover 15–20 kHz, got \(pairs.count)")
for pair in pairs {
    expect(pair.highHz - pair.lowHz >= 999, "separation \(pair.label)")
    expect(pair.lowHz >= 15_000 - 0.1 && pair.highHz <= 20_000 + 0.1, "range \(pair.label)")
}
for index in 1..<pairs.count {
    let step = pairs[index].lowHz - pairs[index - 1].lowHz
    expect(abs(step - 500) < 0.1, "step \(step)")
}

// MARK: - 每个 bit 是配置里的单音加静音，没有淡入淡出

let rate = 48_000.0
let fresh = TestConfig()
expectEqual(fresh.toneDurationMs, 30, "tone default")
expectEqual(fresh.silenceDurationMs, 15, "silence default")
expectEqual(fresh.leadSilenceMs, 20, "lead default")
expectEqual(fresh.trailSilenceMs, 20, "trail default")
expectEqual(fresh.symbolDurationMs, 40, "symbol default unchanged")
let packetMs = fresh.normalized.expectedSignalSeconds * 1_000 + fresh.leadSilenceMs + fresh.trailSilenceMs
expect(packetMs < 3_000, "packet under 3 seconds, got \(packetMs)")
let bits: [Bool] = [false, false, true, true, false]
let rendered = CPFSKSynth.render(
    bits: bits,
    f0: 16_000,
    f1: 18_000,
    sampleRate: rate,
    toneMs: fresh.toneDurationMs,
    gapMs: fresh.silenceDurationMs,
    amplitude: 1
)
let toneSamples = Int((fresh.toneDurationMs / 1_000 * rate).rounded())
let gapSamples = Int((fresh.silenceDurationMs / 1_000 * rate).rounded())
expectEqual(rendered.count, bits.count * (toneSamples + gapSamples), "pulse length")
let quarter = sin(2 * Double.pi * 16_000 / rate)
expect(abs(Double(rendered[1]) - quarter) < 1e-4, "tone starts at full amplitude")
var pulseOK = true
for (index, bit) in bits.enumerated() {
    let origin = index * (toneSamples + gapSamples)
    let tone = rendered[origin..<(origin + toneSamples)]
    let gap = rendered[(origin + toneSamples)..<(origin + toneSamples + gapSamples)]
    let frequency = bit ? 18_000.0 : 16_000.0
    let other = bit ? 16_000.0 : 18_000.0
    let onPulse = Goertzel.power(samples: tone, sampleRate: rate, frequency: frequency)
    let offPulse = Goertzel.power(samples: tone, sampleRate: rate, frequency: other)
    if onPulse <= offPulse * 20 || gap.contains(where: { $0 != 0 }) {
        pulseOK = false
    }
}
expect(pulseOK, "each bit is the matching tone followed by silence")

// MARK: - Goertzel 能分出目标音

var tone = [Float](repeating: 0, count: 4_096)
for index in tone.indices {
    tone[index] = sin(2 * Float.pi * 16_000 * Float(index) / Float(rate))
}
let onTarget = Goertzel.power(samples: tone[...], sampleRate: rate, frequency: 16_000)
let offTarget = Goertzel.power(samples: tone[...], sampleRate: rate, frequency: 17_000)
expect(onTarget > offTarget * 20, "goertzel should prefer 16 kHz over 17 kHz")

func feed(_ receiver: SignalAnalyzer.Receiver, audio: [Float], rate: Double, started: Date) {
    var index = 0
    let chunk = 4_096
    while index < audio.count {
        let end = min(audio.count, index + chunk)
        let at = started.addingTimeInterval(Double(index) / rate)
        receiver.ingest(Array(audio[index..<end]), at: at, sampleRate: rate)
        index = end
    }
}

// MARK: - 端到端：合成信号、定位、评分、CSV

struct Noise {
    var state: UInt64 = 1
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1
        let unit = Double(state >> 40) / Double(1 << 24)
        return Float((unit - 0.5) * 0.002)
    }
}

var config = TestConfig()
config.repeats = 3
config.leadSilenceMs = 20
config.trailSilenceMs = 20
config.symbolDurationMs = 20
let testPairs = [
    PlannedPair(lowHz: 16_000, highHz: 17_000),
    PlannedPair(lowHz: 17_500, highHz: 18_500)
]
var audio: [Float] = []
var noise = Noise()
var sent: [SentPacket] = []
var expectedStarts: [Int] = []
audio.append(contentsOf: repeatElement(0, count: Int(0.5 * rate)))
var sequence = 0
for pair in testPairs {
    for repeatIndex in 0..<config.repeats {
        sequence += 1
        let payload = PacketLayout.encode(lowHz: pair.lowHz, highHz: pair.highHz, sequence: repeatIndex, random: UInt64(sequence))
        let buffer = CPFSKSynth.playback(
            bits: PacketLayout.bits(for: payload),
            f0: pair.lowHz,
            f1: pair.highHz,
            sampleRate: rate,
            toneMs: config.toneDurationMs,
            gapMs: config.silenceDurationMs,
            leadMs: config.leadSilenceMs,
            trailMs: config.trailSilenceMs
        )
        var noisy = buffer
        for index in noisy.indices {
            noisy[index] += noise.next()
        }
        let lead = Int((config.leadSilenceMs / 1_000 * rate).rounded())
        if sequence == 1 {
            let step = toneSamples + gapSamples
            let bitStart = lead + 3 * step
            let hole = Int((0.005 * rate).rounded())
            let holeStart = bitStart + toneSamples / 2
            for index in holeStart..<(holeStart + hole) {
                noisy[index] = 0
            }
        }
        expectedStarts.append(audio.count + lead)
        audio.append(contentsOf: noisy)
        sent.append(SentPacket(
            sequence: sequence,
            repeatIndex: repeatIndex,
            lowHz: pair.lowHz,
            highHz: pair.highHz,
            payloadHex: PacketFactory.hex(payload),
            watchSendTimestamp: 1_700_000_000 + Double(sequence)
        ))
    }
}

let samplePacket = PacketLayout.encode(lowHz: 16_000, highHz: 17_000, sequence: 2, random: 0x1_5555_5555)
expectEqual(PacketLayout.bits(for: samplePacket).count, 64, "64 bits")
let sampleFields = PacketLayout.decode(samplePacket)
expect(sampleFields.lowHz == 16_000, "decoded low")
expect(sampleFields.highHz == 17_000, "decoded high")
expectEqual(sampleFields.sequence, 2, "decoded sequence")
expect(!sampleFields.corrected, "clean packet is not corrected")
let flippedWord = PacketLayout.word(from: samplePacket) ^ (UInt64(1) << 20)
let flipped = ExtendedHamming.correct(word: flippedWord)
expect(flipped.corrected, "single bit is corrected")
expectEqual(flipped.word, PacketLayout.word(from: samplePacket), "single bit restores the word")
let doubleWord = PacketLayout.word(from: samplePacket) ^ (UInt64(1) << 20) ^ (UInt64(1) << 21)
let doubled = ExtendedHamming.correct(word: doubleWord)
expect(doubled.status == .uncorrectable, "two bit errors stay uncorrected")

let started = Date(timeIntervalSince1970: 1_700_000_000)
let schedule = testPairs.flatMap { pair in Array(repeating: pair, count: config.repeats) }
let live = SignalAnalyzer.Receiver(config: config, schedule: schedule)
var phoneLogs: [String] = []
live.onLog = { phoneLogs.append($0) }
feed(live, audio: audio, rate: rate, started: started)
expect(live.retainedSampleCount < audio.count / 2, "window released processed audio, kept \(live.retainedSampleCount)")
for packet in sent.reversed() { live.note(packet) }
let analysisPairs = live.finish()
let analysisTransmissions = analysisPairs.flatMap(\.transmissions).sorted { $0.packet.sequence < $1.packet.sequence }
expectEqual(analysisTransmissions.count, sent.count, "transmission count")
for (transmission, expected) in zip(analysisTransmissions, expectedStarts) {
    guard let phoneReceiveDate = transmission.phoneReceiveDate else {
        expect(false, "packet \(transmission.packet.sequence) missing date")
        continue
    }
    let actual = Int(phoneReceiveDate.timeIntervalSince(started) * rate)
    let delta = abs(actual - expected)
    expect(delta < Int(0.12 * rate), "packet \(transmission.packet.sequence) callback date within 120 ms, delta samples \(delta)")
    expect(transmission.demodEndDate != nil, "packet \(transmission.packet.sequence) demod end")
    expect(transmission.detected, "packet \(transmission.packet.sequence) detected")
    expect(transmission.passed, "packet \(transmission.packet.sequence) payload matches")
    expect(transmission.decodedSequence == transmission.packet.repeatIndex, "decoded sequence")
    expect(transmission.decodedLowHz == transmission.packet.lowHz, "decoded low")
    expect(transmission.decodedHighHz == transmission.packet.highHz, "decoded high")
    expect(transmission.packetSNRdB >= 20, "packet snr \(transmission.packetSNRdB)")
}
for sequence in 1...sent.count {
    expect(phoneLogs.contains { line in
        line.hasPrefix("包 \(sequence) 前导对齐=是 解出=")
            && line.contains(" 通过=是 解调耗时=")
            && line.contains(" 解出序号=")
            && line.contains(" 是否纠错=")
            && line.contains(" 纠错后是否通过=是")
    }, "result log \(sequence)")
    expect(phoneLogs.contains { line in
        line.hasPrefix("解调=成功 ")
            && line.contains(" 校验=通过 ")
            && line.contains(" 解出hex=")
            && line.contains(" 匹配=无对应包")
    }, "demod log \(sequence)")
    expect(phoneLogs.contains { $0.hasPrefix("包 \(sequence) 结束后窗口剩余 ") && $0.hasSuffix(" 样本") }, "window log \(sequence)")
}
expectEqual(analysisPairs.count, 2, "two frequency pairs")
for pair in analysisPairs {
    expect(pair.score.total >= 80, "\(pair.label) score \(pair.score.total) should be recommended")
    expect(pair.isRecommended, "recommended flag")
    expect(pair.passRate == 1, "cpfsk pass rate \(pair.passRate)")
    expectEqual(pair.score.passRate, 40, "full pass-rate points")
}

let mismatched = sent.map { packet -> SentPacket in
    var copy = packet
    copy.payloadHex = "ffffffffffffffff"
    return copy
}
let mismatchReceiver = SignalAnalyzer.Receiver(config: config, schedule: schedule)
feed(mismatchReceiver, audio: audio, rate: rate, started: started)
for packet in mismatched { mismatchReceiver.note(packet) }
let mismatchPairs = mismatchReceiver.finish()
for transmission in mismatchPairs.flatMap(\.transmissions) {
    expect(transmission.detected, "wrong payload still has energy \(transmission.packet.sequence)")
    expect(!transmission.passed, "wrong payload is not a pass \(transmission.packet.sequence)")
}
expect(mismatchPairs.allSatisfy { $0.passRate == 0 && $0.score.passRate == 0 }, "energy without matching bits scores no pass rate")

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AquaEchoSelfCheck", isDirectory: true)
let csvURL = try CSVExporter.write(pairs: analysisPairs, mode: .cpfsk, directory: folder)
let csv = try String(contentsOf: csvURL, encoding: .utf8)
expect(csvURL.lastPathComponent.hasPrefix("AquaEcho_Results_"), "csv name \(csvURL.lastPathComponent)")
expect(csv.contains("频率对"), "csv header")
expect(csv.contains("Watch发送时间"), "watch time column")
expect(csv.contains("iPhone接收时间"), "phone time column")
expect(csv.contains("平均SNR_dB"), "snr column")
expect(!csv.contains("稳定性"), "stability column removed")
expect(!csv.contains("可解码性"), "decodability column removed")
expect(csv.contains("双频能量比_dB"), "ratio column")
expect(csv.contains("通过率"), "pass-rate column")
expect(csv.contains("本包是否通过"), "per-packet pass column")
expect(csv.contains("解调结束时间"), "demod end column")
expect(csv.contains("解出低频"), "decoded low column")
expect(csv.contains("解出高频"), "decoded high column")
expect(csv.contains("解出序号"), "decoded sequence column")
expect(csv.contains("是否纠错"), "correction column")
expect(!csv.contains("ggwave"), "ggwave column removed")
expect(csv.contains("总分"), "total column")
expect(csv.contains(sent[0].payloadHex), "payload hex")
let lines = csv.split(separator: "\n")
expectEqual(lines.count, sent.count + 1, "one header plus one row per packet")

// 静音不应得到高分。
let silentReceiver = SignalAnalyzer.Receiver(
    config: config,
    schedule: [PlannedPair(lowHz: 16_000, highHz: 17_000)]
)
feed(silentReceiver, audio: [Float](repeating: 0, count: Int(rate * 2)), rate: rate, started: started)
silentReceiver.note(SentPacket(sequence: 1, repeatIndex: 0, lowHz: 16_000, highHz: 17_000, payloadHex: "0011223344556677", watchSendTimestamp: 1_700_000_000))
let silent = silentReceiver.finish()
expect(silent[0].meanSNRdB < 5, "silence snr \(silent[0].meanSNRdB)")
expect(silent[0].score.snr == 0, "silence snr points")
expect(!silent[0].transmissions[0].passed, "silence is not a pass")
expect(silent[0].score.total < 40, "silence total \(silent[0].score.total)")
expect(phoneLogs.filter { $0.hasPrefix("解调=") }.count == sent.count, "only full 64-bit frames log demod")
let peakLogs = phoneLogs.filter { $0.hasPrefix("检测峰值 SNR=") && $0.contains(" 能量比=") }
let wholeSeconds = Int(Double(audio.count) / rate)
expect(peakLogs.count >= wholeSeconds - 1, "one peak log per audio second, got \(peakLogs.count)")

var shortTone = [Float](repeating: 0, count: Int(0.008 * rate))
for index in shortTone.indices {
    shortTone[index] = 0.98 * sin(2 * Float.pi * 16_000 * Float(index) / Float(rate))
}
let shortReceiver = SignalAnalyzer.Receiver(
    config: config,
    schedule: [PlannedPair(lowHz: 16_000, highHz: 17_000)]
)
var shortLogs: [String] = []
shortReceiver.onLog = { shortLogs.append($0) }
feed(shortReceiver, audio: shortTone, rate: rate, started: started)
_ = shortReceiver.finish()
expect(shortLogs.contains { $0.hasPrefix("丢弃脉冲 频率=低 ") && $0.hasSuffix(" 原因=短于16ms") }, "discard short pulse \(shortLogs)")
expect(shortLogs.allSatisfy { !$0.hasPrefix("解调=") }, "short pulse does not finish a frame")

if failures.isEmpty {
    print("SELF_CHECK_OK \(analysisPairs.map { "\($0.label)=\($0.score.total)" }.joined(separator: ", "))")
} else {
    fputs("\(failures.count) failure(s)\n", stderr)
    exit(1)
}
