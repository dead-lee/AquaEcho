import Foundation

enum ScanCSVExporter {
    static let headers = [
        "场景", "距离cm", "备注", "集合", "集合名称", "子载波数", "包序号",
        "是否检出", "通过", "期望hex", "解出hex", "SNR_dB", "前导相关",
        "airtime_ms", "接收时间", "构建"
    ]

    static func write(_ analysis: ScanAnalysis, directory: URL? = nil) throws -> URL {
        let folder = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "AquaEcho_Scan_\(analysis.config.scenario.fileTag)_\(formatter.string(from: Date())).csv"
        let url = folder.appendingPathComponent(name)

        var text = "\u{FEFF}" + headers.joined(separator: ",") + "\n"
        for packet in analysis.packets {
            let row = [
                analysis.config.scenario.title,
                number(analysis.config.distanceCm, digits: 1),
                field(analysis.config.notes),
                packet.setID,
                packet.setTitle,
                String(packet.carrierCount),
                String(packet.packetIndex),
                packet.detected ? "1" : "0",
                packet.passed ? "1" : "0",
                packet.expectedHex,
                packet.decodedHex ?? "",
                number(packet.snrDB, digits: 2),
                number(packet.markerSNRDB, digits: 2),
                number(packet.airtimeMs, digits: 1),
                packet.timestamp.map { RunLog.timestamp($0) } ?? "",
                AppBuild.number
            ]
            text += row.joined(separator: ",") + "\n"
        }
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    /// 每个场景一份可读的调试日志，含分析器逐事件/逐缺失行。
    static func writeLog(_ analysis: ScanAnalysis, directory: URL? = nil) throws -> URL {
        let folder = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "AquaEcho_ScanLog_\(analysis.config.scenario.fileTag)_\(formatter.string(from: Date())).txt"
        let url = folder.appendingPathComponent(name)

        var text = ""
        text += "构建=\(AppBuild.number)\n"
        text += "场景=\(analysis.config.scenario.title)\n"
        text += "距离=\(number(analysis.config.distanceCm, digits: 1))cm\n"
        text += "备注=\(analysis.config.notes)\n"
        text += "每组包数=\(analysis.config.packetsPerSet)\n"
        text += "开始=\(RunLog.timestamp(analysis.startedAt))\n"
        text += "结束=\(RunLog.timestamp(analysis.finishedAt))\n"
        text += "采样率=\(Int(analysis.sampleRate.rounded()))\n"
        text += "总包=\(analysis.overallPackets) 通过=\(analysis.overallPassed) 成功率=\(number(analysis.overallRate * 100, digits: 1))%\n"
        text += "\n--- 分析日志 ---\n"
        text += analysis.logLines.joined(separator: "\n") + "\n"
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    private static func number(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func field(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
