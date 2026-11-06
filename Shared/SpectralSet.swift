import Foundation

/// 一组候选子载波（spectral set，频谱集合）。子载波间隔固定 50 Hz。
/// 实时目录只放 0.5–2.5 kHz 的差分 OFDM。
struct SpectralSet: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let lowHz: Double
    let highHz: Double
    let markerHz: Double
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

    /// 集合在 `SpectralSet.all` 里的固定序号，写进 64 bit 载荷的 set code。
    var code: Int { SpectralSet.all.firstIndex(where: { $0.id == id }) ?? 0 }

    /// 全部落在 500–2500 Hz。高沿是开区间上界，最后一个载波是 highHz − 50。
    static let all: [SpectralSet] = [
        SpectralSet(id: "A8", title: "A8 · OFDM 8 载波 0.50–0.90 kHz", lowHz: 500, highHz: 900, markerHz: 0, chirpLowHz: 500, chirpHighHz: 900),
        SpectralSet(id: "B8", title: "B8 · OFDM 8 载波 1.00–1.40 kHz", lowHz: 1_000, highHz: 1_400, markerHz: 0, chirpLowHz: 1_000, chirpHighHz: 1_400),
        SpectralSet(id: "C8", title: "C8 · OFDM 8 载波 1.60–2.00 kHz", lowHz: 1_600, highHz: 2_000, markerHz: 0, chirpLowHz: 1_600, chirpHighHz: 2_000),
        SpectralSet(id: "D16", title: "D16 · OFDM 16 载波 0.50–1.30 kHz", lowHz: 500, highHz: 1_300, markerHz: 0, chirpLowHz: 500, chirpHighHz: 1_300),
        SpectralSet(id: "E16", title: "E16 · OFDM 16 载波 1.20–2.00 kHz", lowHz: 1_200, highHz: 2_000, markerHz: 0, chirpLowHz: 1_200, chirpHighHz: 2_000),
        SpectralSet(id: "S0", title: "S0 · OFDM 20 载波 0.50–1.50 kHz", lowHz: 500, highHz: 1_500, markerHz: 0, chirpLowHz: 500, chirpHighHz: 1_500),
        SpectralSet(id: "S1", title: "S1 · OFDM 30 载波 1.00–2.50 kHz", lowHz: 1_000, highHz: 2_500, markerHz: 0, chirpLowHz: 1_000, chirpHighHz: 2_500),
        SpectralSet(id: "A40", title: "A40 · OFDM 40 载波 0.50–2.50 kHz", lowHz: 500, highHz: 2_500, markerHz: 0, chirpLowHz: 500, chirpHighHz: 2_500)
    ]

    /// 空气里通过率最高的两组。顺序跟 `all` 一致。
    static let defaultIDs: [String] = ["E16", "S1"]

    static func set(id: String) -> SpectralSet? {
        all.first { $0.id == id }
    }
}
