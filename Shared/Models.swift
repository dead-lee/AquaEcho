import Foundation

enum WCKind: String, Codable {
    case config
    case start
    case stop
    case ready
    case volumeLow
    case endWorkout
    case workoutEnded
    case finished
    case log
    /// 手表按了“延时开始”，`startAt` 是开始发送的时刻。
    case countdown
}

/// WatchConnectivity 只承载两件事：水面同步场景配置、回传手表日志。
/// 声波数据不经过这里。
struct WCEnvelope: Codable {
    var kind: WCKind
    var scanConfig: ScanRunConfig? = nil
    var log: String? = nil
    var startAt: Date? = nil
}

enum WCCodec {
    static func encode(_ envelope: WCEnvelope) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(envelope),
              let json = String(data: data, encoding: .utf8) else {
            return [:]
        }
        return ["json": json]
    }

    static func decode(_ message: [String: Any]) -> WCEnvelope? {
        guard let json = message["json"] as? String, let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(WCEnvelope.self, from: data)
    }
}
