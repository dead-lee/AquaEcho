import Foundation

/// 候选频段。手机在这个范围内选频，手表在握手完成前也用它生成探测前导。
struct FrequencyConfig: Codable, Equatable {
    var candidateLowHz: Double = 1_000
    var candidateHighHz: Double = 4_000
}
