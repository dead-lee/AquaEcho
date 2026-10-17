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
expectEqual(pairs.count, 1, "one watercomms band, got \(pairs.count)")
expect(abs(pairs[0].lowHz - 1_000) < 0.1 && abs(pairs[0].highHz - 4_000) < 0.1, "band \(pairs[0].label)")

// MARK: - OFDM 参数和整包时长

let rate = 48_000.0
let fresh = TestConfig()
expectEqual(fresh.symbolDurationMs, 20, "symbol default")
expectEqual(fresh.cyclicPrefixMs, 1.4, "cyclic prefix default")
expectEqual(fresh.chirpDurationMs, 100, "chirp default")
expectEqual(fresh.silenceDurationMs, 20, "gap default")
expectEqual(fresh.leadSilenceMs, 20, "lead default")
expectEqual(fresh.trailSilenceMs, 20, "trail default")
let packetMs = fresh.normalized.expectedSignalSeconds * 1_000 + fresh.leadSilenceMs + fresh.trailSilenceMs
expect(packetMs < 3_000, "packet under 3 seconds, got \(packetMs)")
var longerSymbol = fresh
longerSymbol.symbolDurationMs = 40
expect(
    OFDMModem.signalSeconds(f0: 16_000, f1: 17_000, config: longerSymbol)
        > OFDMModem.signalSeconds(f0: 16_000, f1: 17_000, config: fresh),
    "symbol duration changes the packet"
)
let probePayload = PacketLayout.encode(lowHz: 1_000, highHz: 4_000, sequence: 0, random: 1)
let probeBits = PacketLayout.bits(for: probePayload)
let probeCoded = ConvolutionalCode.encode(probeBits)
expectEqual(probeCoded.count, ConvolutionalCode.encodedBitCount, "coded length")
expectEqual(ConvolutionalCode.decode(probeCoded), probeBits, "viterbi round trip")
var damagedCode = probeCoded
damagedCode[40].toggle()
expectEqual(ConvolutionalCode.decode(damagedCode), probeBits, "viterbi corrects one coded bit")
let symbolOrder = OFDMModem.interleaveOrder(count: 60, symbolIndex: 0)
expectEqual(
    symbolOrder,
    [7, 18, 39, 19, 37, 35, 25, 16, 33, 49, 58, 54, 4, 24, 6, 55, 26, 31, 36, 59, 38, 2, 1, 46, 32, 10, 20, 9, 42, 5, 48, 52, 45, 51, 30, 8, 34, 22, 15, 23, 57, 41, 12, 28, 14, 43, 21, 50, 44, 27, 17, 3, 47, 53, 13, 56, 11, 29, 40, 0],
    "symbol 0 uses java.util.Random seed 0"
)
expect(
    OFDMModem.interleaveOrder(count: 60, symbolIndex: 1) != symbolOrder,
    "symbol 1 uses a different seed"
)
let scattered = [symbolOrder[29], symbolOrder[30], symbolOrder[31], symbolOrder[32]]
expect(Set(scattered).count == 4 && (scattered.max()! - scattered.min()!) > 3, "adjacent carriers are not adjacent coded bits \(scattered)")
var pattern = Array(repeating: false, count: 60)
for index in [1, 4, 9, 29, 30, 31, 32] {
    pattern[index] = true
}
expectEqual(
    OFDMModem.deinterleave(OFDMModem.interleave(pattern, symbolIndex: 2), symbolIndex: 2),
    pattern,
    "symbol 2 interleave round trip"
)
let rendered = OFDMModem.playback(
    bits: probeCoded,
    f0: 1_000,
    f1: 4_000,
    config: fresh
)
let probePlan = OFDMModem.plan(f0: 1_000, f1: 4_000, config: fresh, bitCount: probeCoded.count)
let leadSamples = Int((fresh.leadSilenceMs / 1_000 * rate).rounded())
let trailSamples = Int((fresh.trailSilenceMs / 1_000 * rate).rounded())
expectEqual(rendered.count, leadSamples + probePlan.packetSamples + trailSamples, "packet length")
expectEqual(probePlan.preamble.count, 9_360, "naiser3 length")
expectEqual(probePlan.gap, 960, "chirp gap")
var late = [Float](repeating: 0, count: 80_000)
let lateAt = 70_000
for (offset, sample) in probePlan.preamble.enumerated() {
    late[lateAt + offset] = sample
}
let lateCorrelation = OFDMModem.correlate(signal: late, template: probePlan.preamble)
if let peak = lateCorrelation.indices.max(by: { lateCorrelation[$0] < lateCorrelation[$1] }) {
    expect(abs(peak - lateAt) <= 2, "late preamble correlation peak \(peak)")
} else {
    expect(false, "late preamble correlation")
}
expectEqual(probePlan.ns, 960, "symbol length")
expectEqual(probePlan.cp, 67, "cyclic prefix")
let preamble = rendered[leadSamples..<(leadSamples + probePlan.preamble.count)]
let preamblePeak = preamble.map { abs($0) }.max() ?? 0
expect(abs(Double(preamblePeak) - 0.98) < 0.02, "preamble peak \(preamblePeak)")
let guardPeak = preamble.dropFirst(960).prefix(240).map { abs($0) }.max() ?? 1
expect(guardPeak < 0.001, "naiser guard is silence, peak \(guardPeak)")
var preambleWithGap = Array(preamble)
preambleWithGap.append(contentsOf: repeatElement(0, count: probePlan.gap))
if let locked = OFDMModem.naiserLock(samples: preambleWithGap, peakIndex: 0) {
    expect(locked.score >= 0.95, "naiser metric \(locked.score)")
} else {
    expect(false, "naiser lock on the preamble")
}
if let roundTrip = OFDMModem.demodulate(window: Array(rendered), symbolStart: leadSamples + probePlan.preamble.count + probePlan.gap, plan: probePlan) {
    expectEqual(ConvolutionalCode.decode(roundTrip.bits), probeBits, "ofdm round trip")
} else {
    expect(false, "ofdm round trip produced no bits")
}
var dirty = rendered
for index in dirty.indices {
    dirty[index] += 0.8 * sin(2 * Float.pi * 8_000 * Float(index) / Float(rate))
}
let noisyReceiver = SignalAnalyzer.Receiver(
    config: fresh,
    schedule: [PlannedPair(lowHz: 1_000, highHz: 4_000)]
)
feed(noisyReceiver, audio: dirty, rate: rate, started: Date(timeIntervalSince1970: 1_700_000_000))
noisyReceiver.note(SentPacket(
    sequence: 1,
    repeatIndex: 0,
    lowHz: 1_000,
    highHz: 4_000,
    payloadHex: PacketFactory.hex(probePayload),
    watchSendTimestamp: 1_700_000_000
))
let noisyPacket = noisyReceiver.finish().flatMap(\.transmissions).first
expect(noisyPacket?.passed == true, "loud out-of-band tone still decodes")

// MARK: - Goertzel 能分出目标音

var tone = [Float](repeating: 0, count: 4_096)
for index in tone.indices {
    tone[index] = sin(2 * Float.pi * 16_000 * Float(index) / Float(rate))
}
let onTarget = Goertzel.power(samples: tone[...], sampleRate: rate, frequency: 16_000)
let offTarget = Goertzel.power(samples: tone[...], sampleRate: rate, frequency: 17_000)
expect(onTarget > offTarget * 20, "goertzel should prefer 16 kHz over 17 kHz")

func playbackPacket(_ payload: Data, lowHz: Double, highHz: Double, coded: [Bool]? = nil) -> [Float] {
    let bits = coded ?? ConvolutionalCode.encode(PacketLayout.bits(for: payload))
    return OFDMModem.playback(bits: bits, f0: lowHz, f1: highHz, config: fresh)
}

func flippedCodedBits(_ payload: Data, at indexes: [Int]) -> [Bool] {
    var bits = ConvolutionalCode.encode(PacketLayout.bits(for: payload))
    for index in indexes where bits.indices.contains(index) {
        bits[index].toggle()
    }
    return bits
}

/// 前导和训练符号保留，数据符号换成噪声。对应真机第 4 包：前导还在，后面的符号已经不像发出去的载荷。
func wipeDataSymbols(_ packet: [Float], lowHz: Double, highHz: Double) -> [Float] {
    let plan = OFDMModem.plan(
        f0: lowHz,
        f1: highHz,
        config: fresh,
        bitCount: ConvolutionalCode.encodedBitCount
    )
    var copy = packet
    let lead = Int((fresh.leadSilenceMs / 1_000 * rate).rounded())
    let dataStart = lead + plan.preamble.count + plan.gap + plan.symbolSamples
    let dataEnd = min(copy.count, lead + plan.packetSamples)
    guard dataStart < dataEnd else { return copy }
    var state: UInt64 = 99
    for index in dataStart..<dataEnd {
        state = state &* 6364136223846793005 &+ 1
        let unit = Float(state >> 40) / Float(1 << 24)
        copy[index] = (unit - 0.5) * 0.2
    }
    return copy
}

func placePackets(_ items: [(at: Int, samples: [Float])], length: Int) -> [Float] {
    var audio = [Float](repeating: 0, count: length)
    for item in items {
        for (offset, sample) in item.samples.enumerated() {
            let index = item.at + offset
            if audio.indices.contains(index) {
                audio[index] = sample
            }
        }
    }
    return audio
}

func receivePackets(
    _ audio: [Float],
    schedule: [PlannedPair],
    packets: [SentPacket],
    oneShot: Bool = false
) -> (transmissions: [Transmission], logs: [String]) {
    let receiver = SignalAnalyzer.Receiver(config: fresh, schedule: schedule)
    var logs: [String] = []
    receiver.onLog = { logs.append($0) }
    for packet in packets {
        receiver.note(packet)
    }
    if oneShot {
        receiver.ingest(audio, at: started, sampleRate: rate)
    } else {
        feed(receiver, audio: audio, rate: rate, started: started)
    }
    return (
        receiver.finish().flatMap(\.transmissions).sorted { $0.packet.sequence < $1.packet.sequence },
        logs
    )
}

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
config.cyclicPrefixMs = 1.4
let testPairs = [
    PlannedPair(lowHz: 1_000, highHz: 2_500),
    PlannedPair(lowHz: 2_500, highHz: 4_000)
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
        let buffer = OFDMModem.playback(
            bits: ConvolutionalCode.encode(PacketLayout.bits(for: payload)),
            f0: pair.lowHz,
            f1: pair.highHz,
            config: config
        )
        var noisy = buffer
        for index in noisy.indices {
            noisy[index] += noise.next()
        }
        let lead = Int((config.leadSilenceMs / 1_000 * rate).rounded())
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
expect(!sampleFields.corrected, "payload itself is not a checksum")
let data56: UInt64 = 0x0123_4567_89AB_CD
let hammingWord = (data56 << 8) | UInt64(ExtendedHamming.checksum(data56: data56))
let flipped = ExtendedHamming.correct(word: hammingWord ^ (UInt64(1) << 20))
expect(flipped.corrected, "single bit is corrected")
expectEqual(flipped.word, hammingWord, "single bit restores the word")
let doubled = ExtendedHamming.correct(word: hammingWord ^ (UInt64(1) << 20) ^ (UInt64(1) << 21))
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

// MARK: - 按真机失败回放：1 bit 可纠正，符号毁掉不能通过，长缓冲后半段和被截掉的尾包

let band = PlannedPair(lowHz: 1_000, highHz: 4_000)
func fieldPacket(_ sequence: Int, _ repeatIndex: Int, _ random: UInt64) -> (payload: Data, sent: SentPacket) {
    let payload = PacketLayout.encode(lowHz: band.lowHz, highHz: band.highHz, sequence: repeatIndex, random: random)
    let sentPacket = SentPacket(
        sequence: sequence,
        repeatIndex: repeatIndex,
        lowHz: band.lowHz,
        highHz: band.highHz,
        payloadHex: PacketFactory.hex(payload),
        watchSendTimestamp: 1_700_000_000 + Double(sequence)
    )
    return (payload, sentPacket)
}

let clean = fieldPacket(1, 0, 0x11)
let oneBit = fieldPacket(2, 1, 0x22)
let wiped = fieldPacket(3, 2, 0x33)
let latePacket = fieldPacket(4, 3, 0x44)
let tail = fieldPacket(5, 4, 0x55)
let cleanAudio = playbackPacket(clean.payload, lowHz: band.lowHz, highHz: band.highHz)
let oneBitAudio = playbackPacket(
    oneBit.payload,
    lowHz: band.lowHz,
    highHz: band.highHz,
    coded: flippedCodedBits(oneBit.payload, at: [17])
)
let wipedAudio = wipeDataSymbols(
    playbackPacket(wiped.payload, lowHz: band.lowHz, highHz: band.highHz),
    lowHz: band.lowHz,
    highHz: band.highHz
)
let lateAudio = playbackPacket(latePacket.payload, lowHz: band.lowHz, highHz: band.highHz)
let tailAudio = playbackPacket(tail.payload, lowHz: band.lowHz, highHz: band.highHz)
let packetSpan = cleanAudio.count
expect(packetSpan < Int(0.5 * rate), "packet fits in the 0.5 s watch spacing, span \(packetSpan)")

// 07:23 那次：包大约落在 0.30、0.80、1.30、1.80 秒，第 5 包会落在 2.40 秒；录音在 2.30 秒被截断。
let origins = [14_400, 38_400, 62_400, 86_400, 115_200]
let fullLength = origins[4] + packetSpan + 4_096
let fullAudio = placePackets([
    (origins[0], cleanAudio),
    (origins[1], oneBitAudio),
    (origins[2], wipedAudio),
    (origins[3], lateAudio),
    (origins[4], tailAudio)
], length: fullLength)
let recordedLength = 110_400
let truncatedAudio = Array(fullAudio.prefix(recordedLength))
let fieldPackets = [clean.sent, oneBit.sent, wiped.sent, latePacket.sent, tail.sent]
let fieldSchedule = Array(repeating: band, count: fieldPackets.count)

let fullRun = receivePackets(fullAudio, schedule: fieldSchedule, packets: fieldPackets)
let fullResult = fullRun.transmissions
expectEqual(fullResult.count, 5, "full field recording has 5 packets")
func field(_ sequence: Int, in result: [Transmission]) -> Transmission? {
    result.first { $0.packet.sequence == sequence }
}
if let first = field(1, in: fullResult) {
    expect(first.passed, "clean packet passes")
    expect(!first.errorCorrected, "clean packet does not claim a correction")
} else {
    expect(false, "clean packet missing")
}
if let second = field(2, in: fullResult) {
    expect(second.passed, "one coded-bit error still passes")
    expect(second.errorCorrected, "one coded-bit error is marked corrected")
} else {
    expect(false, "one coded-bit packet missing")
}
if let third = field(3, in: fullResult) {
    expect(!third.passed, "wiped data symbols are not a pass")
} else {
    expect(false, "wiped packet missing from results")
}
expect(fullRun.logs.contains { $0.hasPrefix("解调=失败 ") }, "wiped packet still writes a failed demod line")
if let fourth = field(4, in: fullResult) {
    expect(fourth.passed, "packet past 65536 samples still passes")
} else {
    expect(false, "late packet missing")
}
if let fifth = field(5, in: fullResult) {
    expect(fifth.passed, "packet after the old 2.3 s cutoff passes when the samples exist")
} else {
    expect(false, "tail packet missing from the full recording")
}

let cutRun = receivePackets(truncatedAudio, schedule: fieldSchedule, packets: fieldPackets)
let cutResult = cutRun.transmissions
if let cutTail = field(5, in: cutResult) {
    expect(!cutTail.passed && cutTail.phoneReceiveDate == nil, "packet past the truncated recording stays missed")
} else {
    expect(false, "truncated recording dropped the tail packet from the result")
}
if let cutLate = field(4, in: cutResult) {
    expect(cutLate.passed, "packet inside the truncated recording still passes")
} else {
    expect(false, "packet 4 missing from the truncated recording")
}
expect(
    cutResult.allSatisfy { $0.packet.sequence != 5 || !$0.passed },
    "truncated tail is not reported as passed"
)

// 一次送进超过 65536 点的整段，前导放在后半段。旧的 FFT 这里会把相关峰变成 0。
var oneShotAudio = [Float](repeating: 0, count: 96_000)
for (offset, sample) in lateAudio.enumerated() {
    oneShotAudio[72_000 + offset] = sample
}
let oneShot = receivePackets(
    oneShotAudio,
    schedule: [band],
    packets: [latePacket.sent],
    oneShot: true
).transmissions
expect(oneShot.first?.passed == true, "one-shot buffer finds the preamble past 65536 samples")

// 前导能锁上、数据符号已经坏掉时，不能算通过，也不能把后面同一频率的好包跳过。
let retryPayload = PacketLayout.encode(lowHz: band.lowHz, highHz: band.highHz, sequence: 1, random: 0x77)
let retrySent = SentPacket(
    sequence: 6,
    repeatIndex: 1,
    lowHz: band.lowHz,
    highHz: band.highHz,
    payloadHex: PacketFactory.hex(retryPayload),
    watchSendTimestamp: 1_700_000_006
)
let advanceAudio = placePackets([
    (4_096, wipedAudio),
    (4_096 + packetSpan + 8_000, playbackPacket(retryPayload, lowHz: band.lowHz, highHz: band.highHz))
], length: 80_000)
let advanceRun = receivePackets(
    advanceAudio,
    schedule: [band, band],
    packets: [wiped.sent, retrySent]
)
let advanceResult = advanceRun.transmissions
if let retried = advanceResult.first(where: { $0.packet.sequence == 6 }) {
    expect(retried.passed, "wiped packet does not swallow the next packet on the same frequency")
} else {
    expect(false, "next packet missing after a wiped packet")
}
expect(advanceResult.first { $0.packet.sequence == 3 }?.passed != true, "wiped packet itself is not a pass")
expect(advanceRun.logs.contains { $0.hasPrefix("解调=失败 ") }, "wiped packet is demodulated and logged as failed")

/// 直达声后面加一个更强的回声。相关峰会锁到回声上；最早到达仍应落在直达声上。
func withEcho(_ packet: [Float], delay: Int, gain: Float) -> [Float] {
    var mixed = [Float](repeating: 0, count: packet.count + delay)
    for (index, sample) in packet.enumerated() {
        mixed[index] += sample
        mixed[index + delay] += gain * sample
    }
    return mixed
}

let echoCase = fieldPacket(7, 0, 0x66)
let echoSource = playbackPacket(echoCase.payload, lowHz: band.lowHz, highHz: band.highHz)
for delay in [36, 60] {
    let mixed = withEcho(echoSource, delay: delay, gain: 2)
    let origin = 8_000
    let buffer = placePackets([(origin, mixed)], length: origin + mixed.count + 4_096)
    let trueStart = origin + leadSamples
    let filtered = OFDMModem.bandpass(buffer, lowHz: band.lowHz, highHz: band.highHz, sampleRate: rate)
    let correlation = OFDMModem.correlate(signal: filtered, template: probePlan.preamble)
    let from = max(0, trueStart - 200)
    let to = min(correlation.count - 1, trueStart + delay + 200)
    var peak = from
    for index in from...to where correlation[index] > correlation[peak] {
        peak = index
    }
    expect(peak >= trueStart + delay - 8, "echo \(delay) pulls the correlation peak late, delta \(peak - trueStart)")
    let arrival = OFDMModem.earliestArrival(
        filtered: filtered,
        correlation: correlation,
        peakIndex: peak,
        preamble: probePlan.preamble,
        sampleRate: rate
    )
    expect(abs(arrival - trueStart) <= 8, "echo \(delay) earliest path delta \(arrival - trueStart)")
    expect(abs(arrival - trueStart) < abs(arrival - (trueStart + delay)), "echo \(delay) sync stays on the direct path")
    let echoed = receivePackets(buffer, schedule: [band], packets: [echoCase.sent]).transmissions
    expect(echoed.first?.passed == true, "echo \(delay) samples still decodes")
}

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
expect(phoneLogs.filter { $0.hasPrefix("解调=") }.count == sent.count, "only full coded frames log demod")
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
expect(shortLogs.allSatisfy { !$0.hasPrefix("解调=") }, "short tone does not finish a frame \(shortLogs)")

if failures.isEmpty {
    print("SELF_CHECK_OK \(analysisPairs.map { "\($0.label)=\($0.score.total)" }.joined(separator: ", "))")
} else {
    fputs("\(failures.count) failure(s)\n", stderr)
    exit(1)
}
