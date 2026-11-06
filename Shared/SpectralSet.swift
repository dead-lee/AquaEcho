import Foundation

/// 一组候选子载波（spectral set，频谱集合）。子载波间隔固定 50 Hz。
/// 实时目录只留 C8 和窄带 C4 两组差分 OFDM。
struct SpectralSet: Identifiable, Equatable, Codable {
    let id: String
    /// 写进 64 bit 载荷的集合号，固定不变。C8 沿用删组前的目录位置，旧录音仍能按原载荷重放。
    let code: Int
    let title: String
    let lowHz: Double
    let highHz: Double
    let markerHz: Double
    /// 前导下扫和同步滤波的频段。可以比数据频段宽：前导太窄时相关主瓣变宽，seekback 起点会提前。
    let chirpLowHz: Double
    let chirpHighHz: Double

    /// 48 kHz / 960 点符号 => 50 Hz 子载波间隔。
    static let carrierSpacingHz = 50.0

    var carriers: [Int] {
        let low = Int((lowHz / Self.carrierSpacingHz).rounded())
        let high = Int((highHz / Self.carrierSpacingHz).rounded()) - 1
        guard high >= low else { return [] }
        return Array(low...high)
    }

    var carrierCount: Int { carriers.count }

    /// 编码比特均分到每个符号。
    var dataSymbols: Int {
        guard carriers.count > 0 else { return 0 }
        return (ConvolutionalCode.encodedBitCount + carriers.count - 1) / carriers.count
    }

    /// 单包空中时间（airtime），单位毫秒。
    var airtimeMs: Double { Double(ScanProtocol.frameSamples(for: self)) / 48.0 }

    var bandLabel: String { "\(HzFormat.string(lowHz))–\(HzFormat.string(highHz)) Hz" }

    /// 高沿是开区间上界，最后一个载波是 highHz − 50。
    static let all: [SpectralSet] = [
        SpectralSet(id: "C8", code: 2, title: "C8 · OFDM 8 载波 1.60–2.00 kHz", lowHz: 1_600, highHz: 2_000, markerHz: 0, chirpLowHz: 1_600, chirpHighHz: 2_000),
        SpectralSet(id: "C4", code: 8, title: "C4 · OFDM 4 载波 1.80–2.00 kHz", lowHz: 1_800, highHz: 2_000, markerHz: 0, chirpLowHz: 1_600, chirpHighHz: 2_000)
    ]

    /// 先 C8 后 C4，真机上直接对照。顺序跟 `all` 一致。
    static let defaultIDs: [String] = ["C8", "C4"]

    static func set(id: String) -> SpectralSet? {
        all.first { $0.id == id }
    }
}
