import Foundation

/// 开发日志。固定写到 App Documents，文件名 `AquaEcho_Log_yyyyMMdd_HHmmss.txt`。
final class RunLog {
    static let shared = RunLog()

    let fileURL: URL
    private let queue = DispatchQueue(label: "AquaEcho.RunLog")
    private var lines: [String] = []
    private var recentMessages: [(String, Date)] = []
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

    func append(_ message: String) {
        let line = "\(Self.timestamp()) \(message)"
        let now = Date()
        let snapshot = queue.sync { () -> String? in
            recentMessages.removeAll { now.timeIntervalSince($0.1) > 2 }
            if recentMessages.contains(where: { $0.0 == message }) { return nil }
            recentMessages.append((message, now))
            lines.append(line)
            return lines.joined(separator: "\n") + "\n"
        }
        guard let snapshot else { return }
        queue.async {
            try? snapshot.write(to: self.fileURL, atomically: true, encoding: .utf8)
        }
        if Thread.isMainThread {
            onAppend?(line)
        } else {
            DispatchQueue.main.async { self.onAppend?(line) }
        }
    }

    func text() -> String {
        queue.sync { lines.joined(separator: "\n") }
    }

    static func documentFiles(prefixes: [String] = ["AquaEcho_Log_", "AquaEcho_Results_"]) -> [URL] {
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
