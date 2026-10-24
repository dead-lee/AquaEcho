import Foundation

/// 64 bit 测试载荷的字节/比特序。扫描协议只关心顺序，不再解释低频/高频字段。
enum PacketLayout {
    static let payloadBytes = 8
    static let bitCount = 64

    static func data(from word: UInt64) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(payloadBytes)
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((word >> shift) & 0xFF))
        }
        return Data(bytes)
    }

    static func bits(for payload: Data) -> [Bool] {
        var bits: [Bool] = []
        bits.reserveCapacity(bitCount)
        let bytes = payload.prefix(payloadBytes)
        for byte in bytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                bits.append(((byte >> shift) & 0x01) == 1)
            }
        }
        if bits.count < bitCount {
            bits.append(contentsOf: repeatElement(false, count: bitCount - bits.count))
        }
        return bits
    }
}

enum PacketFactory {
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

enum HzFormat {
    static func string(_ hz: Double) -> String {
        if abs(hz - hz.rounded()) < 0.05 {
            return String(Int(hz.rounded()))
        }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), hz)
    }
}
