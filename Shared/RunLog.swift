import Foundation

/// 开发日志。固定写到 App Documents，文件名 `AquaEcho_Log_yyyyMMdd_HHmmss.txt`。
/// 追加写文件句柄，避免每行重写整段日志；UI 只拿新增的那一行。
final class RunLog {
    static let shared = RunLog()

    let fileURL: URL
    private let queue = DispatchQueue(label: "AquaEcho.RunLog")
    private var lines: [String] = []
    private var handle: FileHandle?
    var onAppend: ((String) -> Void)?

    private init() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        fileURL = folder.appendingPathComponent("AquaEcho_Log_\(formatter.string(from: Date())).txt")
    }

    deinit {
        try? handle?.close()
    }

    func append(_ message: String) {
        let line = "\(Self.timestamp()) \(message)\n"
        queue.async { [weak self] in
            guard let self else { return }
            self.lines.append(line)
            if self.handle == nil { self.openHandle() }
            if let data = line.data(using: .utf8) {
                try? self.handle?.write(contentsOf: data)
            }
            DispatchQueue.main.async {
                self.onAppend?(line)
            }
        }
    }

    func text() -> String {
        queue.sync { lines.joined() }
    }

    /// 清掉内存和文件，下一次 append 会重新创建文件。
    func discardBufferedLines() {
        queue.sync {
            try? handle?.close()
            handle = nil
            lines.removeAll()
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func openHandle() {
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
    }

    static func documentFiles(prefixes: [String] = [
        "AquaEcho_Log_",
        "AquaEcho_Results_",
        "AquaEcho_Recording_",
        "AquaEcho_Scan_",
        "AquaEcho_ScanLog_"
    ]) -> [URL] {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls
            .filter { url in prefixes.contains { url.lastPathComponent.hasPrefix($0) } }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter.string(from: date)
    }
}
