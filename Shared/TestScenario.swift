import Foundation

/// 三个测试场景。场景只影响手机端的标注和文件名，不改变声波协议。
enum TestScenario: String, CaseIterable, Codable, Identifiable {
    case air
    case airBag
    case waterBag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .air: return "空气"
        case .airBag: return "空气 + 密封袋"
        case .waterBag: return "水下 + 密封袋"
        }
    }

    var detail: String {
        switch self {
        case .air: return "手表裸机、手机不装袋，近距离对准。作为基线。"
        case .airBag: return "手机装进密封袋，仍在空气中；手表裸机。只引入袋子。"
        case .waterBag: return "手机装进密封袋并下水；手表裸机下水。完整目标场景。"
        }
    }

    var fileTag: String {
        switch self {
        case .air: return "air"
        case .airBag: return "air_bag"
        case .waterBag: return "water_bag"
        }
    }
}

struct ScanRunConfig: Codable, Equatable {
    /// 1 是只有 S0–S6 的旧配置。2 起首次打开时把目录里的全部频段都选上。
    static let currentCatalogVersion = 2

    var scenario: TestScenario = .air
    var distanceCm: Double = 1
    var notes: String = ""
    var packetsPerSet: Int = 20
    var setIDs: [String] = SpectralSet.defaultIDs
    var catalogVersion: Int = ScanRunConfig.currentCatalogVersion

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scenario = try container.decodeIfPresent(TestScenario.self, forKey: .scenario) ?? .air
        distanceCm = try container.decodeIfPresent(Double.self, forKey: .distanceCm) ?? 1
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        packetsPerSet = try container.decodeIfPresent(Int.self, forKey: .packetsPerSet) ?? 20
        setIDs = try container.decodeIfPresent([String].self, forKey: .setIDs) ?? SpectralSet.defaultIDs
        catalogVersion = try container.decodeIfPresent(Int.self, forKey: .catalogVersion) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scenario, forKey: .scenario)
        try container.encode(distanceCm, forKey: .distanceCm)
        try container.encode(notes, forKey: .notes)
        try container.encode(packetsPerSet, forKey: .packetsPerSet)
        try container.encode(setIDs, forKey: .setIDs)
        try container.encode(catalogVersion, forKey: .catalogVersion)
    }

    private enum CodingKeys: String, CodingKey {
        case scenario, distanceCm, notes, packetsPerSet, setIDs, catalogVersion
    }

    var normalized: ScanRunConfig {
        var copy = self
        copy.distanceCm = copy.distanceCm.clamped(to: 0...200)
        copy.packetsPerSet = copy.packetsPerSet.clamped(to: 1...200)
        copy.notes = String(copy.notes.prefix(200))
        if copy.catalogVersion < Self.currentCatalogVersion {
            copy.setIDs = SpectralSet.defaultIDs
            copy.catalogVersion = Self.currentCatalogVersion
        }
        let selected = Set(copy.setIDs)
        copy.setIDs = SpectralSet.all.map(\.id).filter { selected.contains($0) }
        return copy
    }

    var activeSets: [SpectralSet] {
        if setIDs.isEmpty { return SpectralSet.all }
        let selected = Set(setIDs)
        return SpectralSet.all.filter { selected.contains($0.id) }
    }

    var label: String {
        var parts = [
            "场景=\(scenario.title)",
            "距离=\(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), distanceCm))cm",
            "每组=\(packetsPerSet)包"
        ]
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append("备注=\(trimmed)") }
        return parts.joined(separator: " ")
    }
}

enum ScanConfigStore {
    static let key = "AquaEcho.ScanRunConfig"

    static func load() -> ScanRunConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(ScanRunConfig.self, from: data) else {
            return ScanRunConfig()
        }
        return config.normalized
    }

    static func save(_ config: ScanRunConfig) {
        let normalized = config.normalized
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
