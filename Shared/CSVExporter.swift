import Foundation

enum CSVExporter {
    static let headers = [
        "模式",
        "频率对",
        "序号",
        "重复序号",
        "随机包内容",
        "Watch发送时间",
        "iPhone接收时间",
        "Watch发送Unix毫秒",
        "iPhone接收Unix毫秒",
        "平均SNR_dB",
        "双频能量比_dB",
        "通过率",
        "SNR得分",
        "双频区分度得分",
        "通过率得分",
        "总分",
        "本包SNR_dB",
        "本包双频能量比_dB",
        "本包是否检出",
        "本包ggwave是否解出",
        "本包是否通过"
    ]

    /// 写入 App Documents。文件名 `AquaEcho_Results_yyyyMMdd_HHmmss.csv`。
    static func write(pairs: [PairScore], mode: TestMode, directory: URL? = nil) throws -> URL {
        let folder = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let url = folder.appendingPathComponent("AquaEcho_Results_\(formatter.string(from: Date())).csv")
        var text = "\u{FEFF}" + headers.joined(separator: ",") + "\n"
        let rows = pairs
            .flatMap { pair in pair.transmissions.map { (pair, $0) } }
            .sorted { $0.1.packet.sequence < $1.1.packet.sequence }
        for (pair, transmission) in rows {
            text += row(pair: pair, transmission: transmission, mode: mode).joined(separator: ",") + "\n"
        }
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    private static func row(pair: PairScore, transmission: Transmission, mode: TestMode) -> [String] {
        let packet = transmission.packet
        let decoded: String
        if let value = transmission.ggwaveDecoded {
            decoded = value ? "1" : "0"
        } else {
            decoded = ""
        }
        return [
            mode.rawValue,
            field(PlannedPair(lowHz: pair.lowHz, highHz: pair.highHz).csvField),
            String(packet.sequence),
            String(packet.repeatIndex),
            field(packet.payloadHex),
            field(timestamp(packet.watchSendDate)),
            field(transmission.phoneReceiveDate.map(timestamp) ?? ""),
            String(milliseconds(packet.watchSendDate)),
            transmission.phoneReceiveDate.map { String(milliseconds($0)) } ?? "",
            number(pair.meanSNRdB, digits: 2),
            number(pair.ratioDB, digits: 2),
            number(pair.passRate * 100, digits: 1),
            String(pair.score.snr),
            String(pair.score.separation),
            String(pair.score.passRate),
            String(pair.score.total),
            number(transmission.packetSNRdB, digits: 2),
            number(transmission.packetRatioDB, digits: 2),
            transmission.detected ? "1" : "0",
            decoded,
            transmission.passed ? "1" : "0"
        ]
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter.string(from: date)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func number(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func field(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
