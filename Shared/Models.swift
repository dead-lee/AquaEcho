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
    var packetPower: Double
    var detected: Bool
    var ggwaveDecoded: Bool?

    var id: Int { packet.sequence }
}

struct ScoreBreakdown: Equatable {
    var snr: Int
    var stability: Int
    var separation: Int
    var decodability: Int

    var total: Int { snr + stability + separation + decodability }
}

struct PairScore: Equatable, Identifiable {
    var mode: TestMode
    var lowHz: Double
    var highHz: Double
    var meanSNRdB: Double
    var stabilityCV: Double
    var ratioDB: Double
    /// 0...1。CPFSK 没有协议解码，为 nil。
    var decodeRate: Double?
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
}

struct WCEnvelope: Codable {
    var kind: WCKind
    var config: TestConfig?
    var packet: SentPacket?
    var packets: [SentPacket]?
    var progress: String?
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
