import Foundation

struct ScanPacketResult: Identifiable, Codable {
    var setID: String
    var setTitle: String
    var carrierCount: Int
    var packetIndex: Int
    var expectedHex: String
    var decodedHex: String?
    var passed: Bool
    var detected: Bool
    var snrDB: Double
    var markerSNRDB: Double
    var airtimeMs: Double
    var frameSample: Int
    var timestamp: Date?

    var id: String { "\(setID)#\(packetIndex)" }
}

struct ScanSetSummary: Identifiable, Codable {
    var setID: String
    var setTitle: String
    var carrierCount: Int
    var packets: Int
    var detected: Int
    var passed: Int
    var successRate: Double
    var meanSNRDB: Double
    var meanMarkerSNRDB: Double
    var airtimeMs: Double
    var corrupt: Int

    var id: String { setID }
}

struct ScanAnalysis: Codable {
    var config: ScanRunConfig
    var startedAt: Date
    var finishedAt: Date
    var sampleRate: Double
    var packets: [ScanPacketResult]
    var summaries: [ScanSetSummary]
    var overallPackets: Int
    var overallPassed: Int
    var overallRate: Double
    var corruptEvents: Int
    var logLines: [String]
}
