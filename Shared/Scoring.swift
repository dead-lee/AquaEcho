import Foundation

/// 评分三项相加，满分 100。
///
/// 边界归入更高一档：信噪比正好 25 dB 记 40 分，正好 20 dB 记 32 分；
/// 双频能量比正好 6 dB 记 20 分；通过率正好 100% 记 40 分，正好 80% 记 32 分。
/// 通过率：载荷逐字节一致的包数 / 总包数。
enum ChannelScore {
    static func snrPoints(_ snrDB: Double) -> Int {
        switch snrDB {
        case 25...: return 40
        case 20..<25: return 32
        case 15..<20: return 24
        case 10..<15: return 16
        case 5..<10: return 8
        default: return 0
        }
    }

    static func separationPoints(ratioDB: Double) -> Int {
        switch ratioDB {
        case 6...: return 20
        case 3..<6: return 12
        case 1..<3: return 6
        default: return 0
        }
    }

    /// 用整数交叉比较，避免 `passed / total` 的二进制舍入把正好 80% 判到下一档。
    static func passRatePoints(passed: Int, total: Int) -> Int {
        guard total > 0, passed > 0 else { return 0 }
        if passed >= total { return 40 }
        if passed * 5 >= total * 4 { return 32 }
        if passed * 5 >= total * 3 { return 24 }
        if passed * 5 >= total * 2 { return 16 }
        if passed * 5 >= total { return 8 }
        return 0
    }

    static func breakdown(snrDB: Double, ratioDB: Double, passedCount: Int, totalCount: Int) -> ScoreBreakdown {
        ScoreBreakdown(
            snr: snrPoints(snrDB),
            separation: separationPoints(ratioDB: ratioDB),
            passRate: passRatePoints(passed: passedCount, total: totalCount)
        )
    }
}
