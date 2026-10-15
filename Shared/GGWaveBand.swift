import Foundation

/// ggwave 超声协议的频率网格。
/// 默认采样率 48 kHz、每帧 1024 点时，每个 FFT 箱约 46.875 Hz，相邻音相差两个箱（93.75 Hz）。
/// `freqStart` 是箱号而不是赫兹。
enum GGWaveBand {
    static let sampleRate = 48_000.0
    static let samplesPerFrame = 1_024.0

    static var hzPerBin: Double { sampleRate / samplesPerFrame }
    static var toneSpacingHz: Double { 2 * hzPerBin }

    static func bin(forHz hz: Double) -> Int {
        Int((hz / hzPerBin).rounded())
    }

    static func hz(forBin bin: Int) -> Double {
        Double(bin) * hzPerBin
    }

    /// 超声协议固定使用 6 个音。返回落在网格上的最低音、最高音和起始箱号。
    static func band(startHz: Double, toneCount: Int = 6) -> (low: Double, high: Double, bin: Int) {
        let bin = bin(forHz: startHz)
        let low = hz(forBin: bin)
        let high = low + 1000
        return (low, high, bin)
    }
}

enum GGWaveProtocolKind: String, Codable, CaseIterable, Identifiable {
    case ultrasoundNormal
    case ultrasoundFast
    case ultrasoundFastest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ultrasoundNormal: return "超声 Normal"
        case .ultrasoundFast: return "超声 Fast"
        case .ultrasoundFastest: return "超声 Fastest"
        }
    }

    /// 每个数据块占用的 ggwave 帧数。Fast 在 48 kHz 下，8 字节变长包实测约 1.32 秒。
    var framesPerTx: Int {
        switch self {
        case .ultrasoundNormal: return 9
        case .ultrasoundFast: return 6
        case .ultrasoundFastest: return 3
        }
    }

    var toneCount: Int { 6 }
}
