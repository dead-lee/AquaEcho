import Foundation

/// 一组候选子载波（spectral set，频谱集合）。子载波间隔固定 50 Hz，
/// 所以每个 bin 对应 50 Hz；集合可以是连续的，也可以是以后从声测结果里挑出的非连续集合。
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

    /// 64 bit 载荷经卷积码后的编码比特数 / 每个符号能承载的比特数。
    var dataSymbols: Int {
        guard carrierCount > 0 else { return 0 }
        return (ConvolutionalCode.encodedBitCount + carrierCount - 1) / carrierCount
    }

    /// 单包空中时间（airtime），单位毫秒。
    var airtimeMs: Double { Double(ScanProtocol.frameSamples(for: self)) / 48.0 }

    var bandLabel: String { "\(HzFormat.string(lowHz))–\(HzFormat.string(highHz)) Hz" }

    /// 集合在 `SpectralSet.all` 里的固定序号，写进 64 bit 载荷的 set code。
    var code: Int { SpectralSet.all.firstIndex(where: { $0.id == id }) ?? 0 }

    static let all: [SpectralSet] = [
        SpectralSet(id: "S0", title: "S0 · 0.5–1.5 kHz", lowHz: 500, highHz: 1_500, markerHz: 600, chirpLowHz: 500, chirpHighHz: 1_500),
        SpectralSet(id: "S1", title: "S1 · 1.0–2.5 kHz", lowHz: 1_000, highHz: 2_500, markerHz: 1_100, chirpLowHz: 1_000, chirpHighHz: 2_500),
        SpectralSet(id: "S2", title: "S2 · 2.0–4.0 kHz", lowHz: 2_000, highHz: 4_000, markerHz: 2_100, chirpLowHz: 2_000, chirpHighHz: 4_000),
        SpectralSet(id: "S3", title: "S3 · 4.0–8.0 kHz", lowHz: 4_000, highHz: 8_000, markerHz: 4_100, chirpLowHz: 4_000, chirpHighHz: 8_000),
        SpectralSet(id: "S4", title: "S4 · 0.5–4.0 kHz", lowHz: 500, highHz: 4_000, markerHz: 700, chirpLowHz: 500, chirpHighHz: 4_000),
        SpectralSet(id: "S5", title: "S5 · 0.5–8.0 kHz", lowHz: 500, highHz: 8_000, markerHz: 800, chirpLowHz: 500, chirpHighHz: 8_000),
        SpectralSet(id: "S6", title: "S6 · 0.5–3.0 kHz", lowHz: 500, highHz: 3_000, markerHz: 900, chirpLowHz: 500, chirpHighHz: 3_000)
    ]

    static let defaultIDs: [String] = all.map(\.id)

    static func set(id: String) -> SpectralSet? {
        all.first { $0.id == id }
    }
}
