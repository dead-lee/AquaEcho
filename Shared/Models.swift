import Foundation

struct SentPacket: Codable, Equatable, Identifiable {
    var sequence: Int
    var repeatIndex: Int
    var lowHz: Double
    var highHz: Double
    var payloadHex: String
    /// Watch 本地时钟，Unix 秒。
    var watchSendTimestamp: TimeInterval

    var id: Int { sequence }

    var watchSendDate: Date { Date(timeIntervalSince1970: watchSendTimestamp) }
}

struct Transmission: Equatable, Identifiable {
    var packet: SentPacket
    var phoneReceiveDate: Date?
    var packetSNRdB: Double
    var packetRatioDB: Double
    var detected: Bool
    /// 解出的 8 字节与发送载荷逐字节一致。
    var passed: Bool

    var id: Int { packet.sequence }
}

struct ScoreBreakdown: Equatable {
    var snr: Int
    var separation: Int
    var passRate: Int

    var total: Int { snr + separation + passRate }
}

struct PairScore: Equatable, Identifiable {
    var mode: TestMode
    var lowHz: Double
    var highHz: Double
    var meanSNRdB: Double
    var ratioDB: Double
    /// 0...1。载荷完全一致的包数 / 该频率对的总包数。
    var passRate: Double
    var score: ScoreBreakdown
    var transmissions: [Transmission]

    var id: String { "\(mode.rawValue)-\(lowHz)-\(highHz)" }
    var label: String { "\(HzFormat.string(lowHz)) / \(HzFormat.string(highHz)) Hz" }
    var isRecommended: Bool { score.total >= 80 }
}

struct CaptureBuffer {
    var samples: [Float]
    var sampleRate: Double
    var startedAt: Date

    func date(forSample index: Int) -> Date {
        let safeRate = max(sampleRate, 1)
        return startedAt.addingTimeInterval(Double(max(0, index)) / safeRate)
    }
}

enum WCKind: String, Codable {
    case config
    case start
    case requestStart
    case stop
    case progress
    case packet
    case finished
    case log
}

struct WCEnvelope: Codable {
    var kind: WCKind
    var config: TestConfig?
    var packet: SentPacket?
    var packets: [SentPacket]?
    var progress: String?
    var log: String? = nil
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
