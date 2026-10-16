import Foundation

enum TestMode: String, Codable, CaseIterable, Identifiable {
    case cpfsk

    var id: String { rawValue }

    var title: String {
        "自定义 CPFSK"
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
    var freqMinHz: Double = 15_000
    var freqMaxHz: Double = 20_000
    var stepHz: Double = 500
    /// CPFSK 两个音的间隔。生成频率对时不会低于 1 kHz。
    var pairSeparationHz: Double = 1_000
    var symbolDurationMs: Double = 40
    var repeats: Int = 5
    var leadSilenceMs: Double = 250
    var trailSilenceMs: Double = 350
    var sampleRate: Double = 48_000

    var normalized: TestConfig {
        var copy = self
        copy.freqMinHz = copy.freqMinHz.clamped(to: 1_000...22_000)
        copy.freqMaxHz = copy.freqMaxHz.clamped(to: 1_000...22_000)
        if copy.freqMaxHz < copy.freqMinHz {
            swap(&copy.freqMinHz, &copy.freqMaxHz)
        }
        copy.stepHz = copy.stepHz.clamped(to: 50...2_000)
        copy.pairSeparationHz = max(1_000, copy.pairSeparationHz)
        copy.symbolDurationMs = copy.symbolDurationMs.clamped(to: 10...200)
        copy.repeats = copy.repeats.clamped(to: 1...30)
        copy.leadSilenceMs = copy.leadSilenceMs.clamped(to: 50...1_000)
        copy.trailSilenceMs = copy.trailSilenceMs.clamped(to: 50...1_500)
        copy.sampleRate = 48_000
        return copy
    }

    /// 从下限按步进取出 f，配对 f 与 f+间隔（间隔至少 1 kHz），且两个音都落在扫描范围内。
    func plannedPairs() -> [PlannedPair] {
        let config = normalized
        var pairs: [PlannedPair] = []
        var frequency = config.freqMinHz
        while frequency + config.pairSeparationHz <= config.freqMaxHz + 0.5 {
            pairs.append(PlannedPair(lowHz: frequency, highHz: frequency + config.pairSeparationHz))
            frequency += config.stepHz
        }
        return pairs
    }

    /// 不含前后静音的信号时长。每个 bit 固定 40 ms 单音加 15 ms 静音。
    var expectedSignalSeconds: Double {
        let bits = Double(PacketLayout.bitCount)
        return bits * (CPFSKSynth.toneMilliseconds + CPFSKSynth.gapMilliseconds) / 1_000
    }

    var estimatedTestSeconds: Double {
        let config = normalized
        let count = Double(config.plannedPairs().count * config.repeats)
        let each = config.expectedSignalSeconds + config.leadSilenceMs / 1_000 + config.trailSilenceMs / 1_000
        return count * each
    }
}

enum ConfigStore {
    static let key = "AquaEcho.TestConfig"

    static func load() -> TestConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(TestConfig.self, from: data) else {
            return TestConfig()
        }
        return config.normalized
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
