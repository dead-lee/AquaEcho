import Foundation

enum TestMode: String, Codable, CaseIterable, Identifiable {
    case cpfsk

    var id: String { rawValue }

    var title: String {
        "OFDM"
    }
}

struct PlannedPair: Codable, Hashable, Identifiable {
    var lowHz: Double
    var highHz: Double

    var id: String { "\(lowHz)-\(highHz)" }

    var label: String { "\(HzFormat.string(lowHz)) / \(HzFormat.string(highHz)) Hz" }

    var csvField: String { "\(HzFormat.string(lowHz))/\(HzFormat.string(highHz))" }
}

struct TestConfig: Codable, Equatable {
    var mode: TestMode = .cpfsk
    var frequency = FrequencyConfig()
    var freqMinHz: Double = 1_000
    var freqMaxHz: Double = 4_000
    var stepHz: Double = 3_000
    /// 这一对 OFDM 占用的带宽。watercomms 默认是 1000–4000 Hz 整段。
    var pairSeparationHz: Double = 3_000
    /// 有用符号长度。20 ms 在 48 kHz 下是 960 点。
    var symbolDurationMs: Double = 20
    /// 旧字段。OFDM 发送不再读取。
    var toneDurationMs: Double = 30
    /// 旧字段。前导和数据之间的间隔采样数是 OFDMConstants.preambleGapSamples，发送不再读取这项。
    var silenceDurationMs: Double = 20
    /// 循环前缀。1.4 ms 在 48 kHz 下是 67 点。
    var cyclicPrefixMs: Double = 1.4
    /// 旧字段。Naiser 前导长度固定，发送不再读取。
    var chirpDurationMs: Double = 100
    var repeats: Int = 5
    var leadSilenceMs: Double = 20
    var trailSilenceMs: Double = 20
    var sampleRate: Double = 48_000

    var normalized: TestConfig {
        var copy = self
        copy.frequency.candidateLowHz = copy.frequency.candidateLowHz.clamped(to: 50...22_000)
        copy.frequency.candidateHighHz = copy.frequency.candidateHighHz.clamped(to: 50...22_000)
        if copy.frequency.candidateHighHz < copy.frequency.candidateLowHz {
            swap(&copy.frequency.candidateLowHz, &copy.frequency.candidateHighHz)
        }
        copy.freqMinHz = copy.frequency.candidateLowHz
        copy.freqMaxHz = copy.frequency.candidateHighHz
        copy.stepHz = copy.stepHz.clamped(to: 50...4_000)
        copy.pairSeparationHz = max(1_000, copy.pairSeparationHz)
        copy.symbolDurationMs = copy.symbolDurationMs.clamped(to: 10...200)
        copy.toneDurationMs = copy.toneDurationMs.clamped(to: 10...500)
        copy.silenceDurationMs = copy.silenceDurationMs.clamped(to: 0...500)
        copy.cyclicPrefixMs = copy.cyclicPrefixMs.clamped(to: 0...50)
        copy.chirpDurationMs = copy.chirpDurationMs.clamped(to: 20...500)
        copy.repeats = copy.repeats.clamped(to: 1...30)
        copy.leadSilenceMs = copy.leadSilenceMs.clamped(to: 0...1_000)
        copy.trailSilenceMs = copy.trailSilenceMs.clamped(to: 0...1_500)
        copy.sampleRate = 48_000
        return copy
    }

    /// 从下限按步进取出 f，配对 f 与 f+带宽（带宽至少 1 kHz），且两端都落在扫描范围内。
    func plannedPairs() -> [PlannedPair] {
        let config = normalized
        var pairs: [PlannedPair] = []
        var frequency = config.frequency.candidateLowHz
        while frequency + config.pairSeparationHz <= config.frequency.candidateHighHz + 0.5 {
            pairs.append(PlannedPair(lowHz: frequency, highHz: frequency + config.pairSeparationHz))
            frequency += config.stepHz
        }
        return pairs
    }

    /// 不含前后静音的信号时长：Naiser 前导、间隔和全部 OFDM 符号。
    var expectedSignalSeconds: Double {
        let config = normalized
        let pair = config.plannedPairs().first
        let low = pair?.lowHz ?? config.frequency.candidateLowHz
        let high = pair?.highHz ?? min(config.frequency.candidateHighHz, low + config.pairSeparationHz)
        return OFDMModem.signalSeconds(f0: low, f1: high, config: config)
    }

    var estimatedTestSeconds: Double {
        let config = normalized
        let count = Double(config.plannedPairs().count * config.repeats)
        let each = config.expectedSignalSeconds + config.leadSilenceMs / 1_000 + config.trailSilenceMs / 1_000
        return count * each
    }
}

extension TestConfig {
    private enum CodingKeys: String, CodingKey {
        case mode
        case frequency
        case freqMinHz
        case freqMaxHz
        case stepHz
        case pairSeparationHz
        case symbolDurationMs
        case toneDurationMs
        case silenceDurationMs
        case cyclicPrefixMs
        case chirpDurationMs
        case repeats
        case leadSilenceMs
        case trailSilenceMs
        case sampleRate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(TestMode.self, forKey: .mode) ?? .cpfsk
        freqMinHz = try container.decodeIfPresent(Double.self, forKey: .freqMinHz) ?? 1_000
        freqMaxHz = try container.decodeIfPresent(Double.self, forKey: .freqMaxHz) ?? 4_000
        if let frequency = try container.decodeIfPresent(FrequencyConfig.self, forKey: .frequency) {
            self.frequency = frequency
        } else {
            frequency = FrequencyConfig(candidateLowHz: freqMinHz, candidateHighHz: freqMaxHz)
        }
        stepHz = try container.decodeIfPresent(Double.self, forKey: .stepHz) ?? 3_000
        pairSeparationHz = try container.decodeIfPresent(Double.self, forKey: .pairSeparationHz) ?? 3_000
        symbolDurationMs = try container.decodeIfPresent(Double.self, forKey: .symbolDurationMs) ?? 20
        toneDurationMs = try container.decodeIfPresent(Double.self, forKey: .toneDurationMs) ?? 30
        silenceDurationMs = try container.decodeIfPresent(Double.self, forKey: .silenceDurationMs) ?? 20
        cyclicPrefixMs = try container.decodeIfPresent(Double.self, forKey: .cyclicPrefixMs) ?? 1.4
        chirpDurationMs = try container.decodeIfPresent(Double.self, forKey: .chirpDurationMs) ?? 100
        repeats = try container.decodeIfPresent(Int.self, forKey: .repeats) ?? 5
        leadSilenceMs = try container.decodeIfPresent(Double.self, forKey: .leadSilenceMs) ?? 20
        trailSilenceMs = try container.decodeIfPresent(Double.self, forKey: .trailSilenceMs) ?? 20
        sampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 48_000
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(freqMinHz, forKey: .freqMinHz)
        try container.encode(freqMaxHz, forKey: .freqMaxHz)
        try container.encode(stepHz, forKey: .stepHz)
        try container.encode(pairSeparationHz, forKey: .pairSeparationHz)
        try container.encode(symbolDurationMs, forKey: .symbolDurationMs)
        try container.encode(toneDurationMs, forKey: .toneDurationMs)
        try container.encode(silenceDurationMs, forKey: .silenceDurationMs)
        try container.encode(cyclicPrefixMs, forKey: .cyclicPrefixMs)
        try container.encode(chirpDurationMs, forKey: .chirpDurationMs)
        try container.encode(repeats, forKey: .repeats)
        try container.encode(leadSilenceMs, forKey: .leadSilenceMs)
        try container.encode(trailSilenceMs, forKey: .trailSilenceMs)
        try container.encode(sampleRate, forKey: .sampleRate)
    }
}

enum ConfigStore {
    static let key = "AquaEcho.TestConfig"

    static func load() -> TestConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(TestConfig.self, from: data) else {
            return TestConfig()
        }
        var loaded = config.normalized
        // 上一版内置默认是 50/20/250/350。这四项都还停在旧默认值时改成 30/20/20/20。
        if loaded.toneDurationMs == 50, loaded.silenceDurationMs == 20,
           loaded.leadSilenceMs == 250, loaded.trailSilenceMs == 350 {
            loaded.toneDurationMs = 30
            loaded.leadSilenceMs = 20
            loaded.trailSilenceMs = 20
            save(loaded)
        }
        // 近超声扫描改成 watercomms 的 1–4 kHz、20 ms 符号和 20 ms 间隔。
        if loaded.frequency.candidateLowHz >= 10_000 || loaded.freqMinHz >= 10_000 {
            loaded.frequency = FrequencyConfig()
            loaded.freqMinHz = loaded.frequency.candidateLowHz
            loaded.freqMaxHz = loaded.frequency.candidateHighHz
            loaded.stepHz = 3_000
            loaded.pairSeparationHz = 3_000
            loaded.symbolDurationMs = 20
            loaded.cyclicPrefixMs = 1.4
            loaded.silenceDurationMs = 20
            save(loaded)
        }
        return loaded
    }

    static func save(_ config: TestConfig) {
        let normalized = config.normalized
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
