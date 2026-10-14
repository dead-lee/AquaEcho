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

expectEqual(ChannelScore.snrPoints(25), 45, "snr 25")
expectEqual(ChannelScore.snrPoints(24.999), 35, "snr just under 25")
expectEqual(ChannelScore.snrPoints(20), 35, "snr 20")
expectEqual(ChannelScore.snrPoints(15), 25, "snr 15")
expectEqual(ChannelScore.snrPoints(10), 15, "snr 10")
expectEqual(ChannelScore.snrPoints(5), 5, "snr 5")
expectEqual(ChannelScore.snrPoints(4.999), 0, "snr under 5")

expectEqual(ChannelScore.stabilityPoints(coefficientOfVariation: 0.099), 20, "cv under 10%")
expectEqual(ChannelScore.stabilityPoints(coefficientOfVariation: 0.10), 15, "cv 10%")
expectEqual(ChannelScore.stabilityPoints(coefficientOfVariation: 0.199), 15, "cv under 20%")
expectEqual(ChannelScore.stabilityPoints(coefficientOfVariation: 0.20), 8, "cv 20%")
expectEqual(ChannelScore.stabilityPoints(coefficientOfVariation: 0.30), 8, "cv 30%")
expectEqual(ChannelScore.stabilityPoints(coefficientOfVariation: 0.3001), 0, "cv over 30%")

expectEqual(ChannelScore.separationPoints(ratioDB: 6), 15, "ratio 6")
expectEqual(ChannelScore.separationPoints(ratioDB: 3), 10, "ratio 3")
expectEqual(ChannelScore.separationPoints(ratioDB: 1), 5, "ratio 1")
expectEqual(ChannelScore.separationPoints(ratioDB: 0.99), 0, "ratio under 1")

expectEqual(ChannelScore.ggwaveDecodability(successRate: 0.95), 20, "decode 95%")
expectEqual(ChannelScore.ggwaveDecodability(successRate: 0.80), 15, "decode 80%")
expectEqual(ChannelScore.ggwaveDecodability(successRate: 0.60), 10, "decode 60%")
expectEqual(ChannelScore.ggwaveDecodability(successRate: 0.40), 5, "decode 40%")
expectEqual(ChannelScore.ggwaveDecodability(successRate: 0.399), 0, "decode under 40%")

expectEqual(ChannelScore.cpfskDecodability(snrPoints: 45, stabilityPoints: 20), 20, "cpfsk full")
expectEqual(ChannelScore.cpfskDecodability(snrPoints: 0, stabilityPoints: 0), 0, "cpfsk zero")
expectEqual(ChannelScore.cpfskDecodability(snrPoints: 45, stabilityPoints: 0), 10, "cpfsk snr only")

let flat = [10.0, 10.0, 10.0]
expectEqual(ChannelScore.coefficientOfVariation(flat), 0, "cv of equals")
let spread = [10.0, 12.0, 8.0]
let spreadCV = ChannelScore.coefficientOfVariation(spread)
expect(abs(spreadCV - 0.2) < 1e-9, "cv of 10/12/8 is 0.2, got \(spreadCV)")

let total = ChannelScore.breakdown(
    mode: .cpfsk,
    snrDB: 30,
    coefficientOfVariation: 0.05,
    ratioDB: 8,
    decodeRate: nil
)
expectEqual(total.snr, 45, "breakdown snr")
expectEqual(total.stability, 20, "breakdown stability")
expectEqual(total.separation, 15, "breakdown separation")
expectEqual(total.decodability, 20, "breakdown decodability")
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

sweep.mode = .ggwave
let bands = sweep.plannedPairs()
expect(!bands.isEmpty, "ggwave sweep empty")
for band in bands {
    expect(band.highHz - band.lowHz > 400, "ggwave bandwidth \(band.label)")
    expect(band.highHz <= 20_001, "ggwave stays in range \(band.label)")
}

// MARK: - 连续相位

let rate = 48_000.0
let bits: [Bool] = [false, false, true, true, false]
let symbol = 0.01
let rendered = CPFSKSynth.render(bits: bits, f0: 16_000, f1: 18_000, symbolSeconds: symbol, sampleRate: rate, amplitude: 1)
let perSymbol = Int((symbol * rate).rounded())
var phase = 0.0
let twoPi = 2 * Double.pi
var phaseOK = true
for (index, bit) in bits.enumerated() {
    let frequency = bit ? 18_000.0 : 16_000.0
    let delta = twoPi * frequency / rate
    for sampleIndex in 0..<perSymbol {
        let expected = sin(phase)
        let actual = Double(rendered[index * perSymbol + sampleIndex])
        if abs(actual - expected) > 1e-4 {
            phaseOK = false
        }
        phase += delta
        if phase >= twoPi { phase -= twoPi }
    }
}
expect(phaseOK, "CPFSK phase stays continuous across symbol boundaries")

// MARK: - Goertzel 能分出目标音

var tone = [Float](repeating: 0, count: 4_096)
for index in tone.indices {
    tone[index] = sin(2 * Float.pi * 16_000 * Float(index) / Float(rate))
}
let onTarget = Goertzel.power(samples: tone[...], sampleRate: rate, frequency: 16_000)
let offTarget = Goertzel.power(samples: tone[...], sampleRate: rate, frequency: 17_000)
expect(onTarget > offTarget * 20, "goertzel should prefer 16 kHz over 17 kHz")

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
config.leadSilenceMs = 200
config.trailSilenceMs = 250
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
        let payload = Data([UInt8(sequence), 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])
        let buffer = CPFSKSynth.playback(
            bits: PacketLayout.bits(for: payload),
            f0: pair.lowHz,
            f1: pair.highHz,
            symbolSeconds: config.symbolDurationMs / 1_000,
            sampleRate: rate,
            leadMs: config.leadSilenceMs,
            trailMs: config.trailSilenceMs
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

let capture = CaptureBuffer(samples: audio, sampleRate: rate, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
let analysis = SignalAnalyzer.analyze(capture: capture, packets: sent, config: config, mode: .cpfsk)
expectEqual(analysis.transmissions.count, sent.count, "transmission count")
for (transmission, expected) in zip(analysis.transmissions, expectedStarts) {
    let actual = Int(transmission.phoneReceiveDate!.timeIntervalSince(capture.startedAt) * rate)
    let delta = abs(actual - expected)
    expect(delta < Int(0.08 * rate), "packet \(transmission.packet.sequence) aligned within 80 ms, delta samples \(delta)")
    expect(transmission.detected, "packet \(transmission.packet.sequence) detected")
    expect(transmission.packetSNRdB >= 20, "packet snr \(transmission.packetSNRdB)")
}
expectEqual(analysis.pairs.count, 2, "two frequency pairs")
for pair in analysis.pairs {
    expect(pair.score.total >= 80, "\(pair.label) score \(pair.score.total) should be recommended")
    expect(pair.isRecommended, "recommended flag")
    expect(pair.decodeRate == nil, "cpfsk has no decode rate")
}

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AquaEchoSelfCheck", isDirectory: true)
let csvURL = try CSVExporter.write(pairs: analysis.pairs, mode: .cpfsk, directory: folder)
let csv = try String(contentsOf: csvURL, encoding: .utf8)
expect(csvURL.lastPathComponent.hasPrefix("AquaEcho_Results_"), "csv name \(csvURL.lastPathComponent)")
expect(csv.contains("频率对"), "csv header")
expect(csv.contains("Watch发送时间"), "watch time column")
expect(csv.contains("iPhone接收时间"), "phone time column")
expect(csv.contains("平均SNR_dB"), "snr column")
expect(csv.contains("稳定性变异系数"), "cv column")
expect(csv.contains("双频能量比_dB"), "ratio column")
expect(csv.contains("ggwave解码成功率"), "decode column")
expect(csv.contains("总分"), "total column")
expect(csv.contains(PacketFactory.hex(Data([1, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]))), "payload hex")
let lines = csv.split(separator: "\n")
expectEqual(lines.count, sent.count + 1, "one header plus one row per packet")

// 静音不应得到高分。
let silence = CaptureBuffer(
    samples: [Float](repeating: 0, count: Int(rate * 2)),
    sampleRate: rate,
    startedAt: Date(timeIntervalSince1970: 1_700_000_000)
)
let silentPacket = [SentPacket(sequence: 1, repeatIndex: 0, lowHz: 16_000, highHz: 17_000, payloadHex: "0011223344556677", watchSendTimestamp: 1_700_000_000)]
let silent = SignalAnalyzer.analyze(capture: silence, packets: silentPacket, config: config, mode: .cpfsk)
expect(silent.pairs[0].meanSNRdB < 5, "silence snr \(silent.pairs[0].meanSNRdB)")
expect(silent.pairs[0].score.snr == 0, "silence snr points")
expect(silent.pairs[0].score.total < 40, "silence total \(silent.pairs[0].score.total)")

if failures.isEmpty {
    print("SELF_CHECK_OK \(analysis.pairs.map { "\($0.label)=\($0.score.total)" }.joined(separator: ", "))")
} else {
    fputs("\(failures.count) failure(s)\n", stderr)
    exit(1)
}
