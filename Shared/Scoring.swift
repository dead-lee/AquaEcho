import Foundation

/// 评分规则与需求一致，四项相加，满分 100。
///
/// 边界归入更高一档的下限：例如 SNR 正好 20 dB 记 35 分，正好 25 dB 记 45 分。
/// 变异系数正好 10% 记 15 分，正好 20% 记 8 分，正好 30% 仍记 8 分，超过 30% 记 0 分。
///
/// CPFSK 没有协议解码。可解码性 = (SNR 得分/45 + 稳定性得分/20) / 2 × 20，四舍五入。
enum ChannelScore {
    static func snrPoints(_ snrDB: Double) -> Int {
        switch snrDB {
        case 25...: return 45
        case 20..<25: return 35
        case 15..<20: return 25
        case 10..<15: return 15
        case 5..<10: return 5
        default: return 0
        }
    }

    static func stabilityPoints(coefficientOfVariation cv: Double) -> Int {
        switch cv {
        case ..<0.10: return 20
        case 0.10..<0.20: return 15
        case 0.20...0.30: return 8
        default: return 0
        }
    }

    static func separationPoints(ratioDB: Double) -> Int {
        switch ratioDB {
        case 6...: return 15
        case 3..<6: return 10
        case 1..<3: return 5
        default: return 0
        }
    }

    static func ggwaveDecodability(successRate: Double) -> Int {
        switch successRate {
        case 0.95...: return 20
        case 0.80..<0.95: return 15
        case 0.60..<0.80: return 10
        case 0.40..<0.60: return 5
        default: return 0
        }
    }

    static func cpfskDecodability(snrPoints: Int, stabilityPoints: Int) -> Int {
        let snrNorm = Double(snrPoints) / 45
        let stabilityNorm = Double(stabilityPoints) / 20
        let scaled = ((snrNorm + stabilityNorm) / 2) * 20
        return Int(scaled.rounded(.toNearestOrAwayFromZero)).clamped(to: 0...20)
    }

    /// 样本变异系数：标准差（除以 n-1） / 均值。衡量各次重复的线性信号能量波动。
    static func coefficientOfVariation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 1e-18 else { return 0 }
        let variance = values.reduce(0) { partial, value in
            let delta = value - mean
            return partial + delta * delta
        } / Double(values.count - 1)
        return sqrt(variance) / mean
    }

    static func breakdown(
        mode: TestMode,
        snrDB: Double,
        coefficientOfVariation cv: Double,
        ratioDB: Double,
        decodeRate: Double?
    ) -> ScoreBreakdown {
        let snr = snrPoints(snrDB)
        let stability = stabilityPoints(coefficientOfVariation: cv)
        let separation = separationPoints(ratioDB: ratioDB)
        let decodability: Int
        switch mode {
        case .ggwave:
            decodability = ggwaveDecodability(successRate: decodeRate ?? 0)
        case .cpfsk:
            decodability = cpfskDecodability(snrPoints: snr, stabilityPoints: stability)
        }
        return ScoreBreakdown(
            snr: snr,
            stability: stability,
            separation: separation,
            decodability: decodability
        )
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
