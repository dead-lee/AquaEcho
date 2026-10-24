import Foundation

/// 64 bit 测试载荷：8 bit 集合号 + 16 bit 包序号 + 40 bit 确定性伪随机数。
/// 手机端不需要 CRC，也不需要手表回传发送内容：它按同样规则重建 64 bit，
/// 逐 bit 比对即可。伪随机部分相当于 40 bit 的自校验。
enum ScanPayload {
    static let setBits = 8
    static let packetBits = 16
    static let randomBits = 40
    static let mask40: UInt64 = (UInt64(1) << 40) - 1

    static func make(setID: String, packetIndex: Int) -> UInt64 {
        let code = SpectralSet.all.firstIndex(where: { $0.id == setID }) ?? 0
        return make(setCode: code, packetIndex: packetIndex)
    }

    static func make(setCode: Int, packetIndex: Int) -> UInt64 {
        let code = UInt64(setCode & 0xFF)
        let packet = UInt64(packetIndex & 0xFFFF)
        let seed = (code << 40) | packet
        let noise = splitMix64(seed: seed) & mask40
        return (code << 56) | (packet << 40) | noise
    }

    static func setCode(of word: UInt64) -> Int { Int((word >> 56) & 0xFF) }
    static func packetIndex(of word: UInt64) -> Int { Int((word >> 40) & 0xFFFF) }

    static func hex(_ word: UInt64) -> String {
        PacketFactory.hex(PacketLayout.data(from: word))
    }

    /// 同一个 seed 在手表和手机上产生同一个 64 bit 数；实现固定，跨平台可复现。
    static func splitMix64(seed: UInt64) -> UInt64 {
        var z = seed &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
