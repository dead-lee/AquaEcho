import Foundation
import Security

enum PacketLayout {
    static let payloadBytes = 8
    /// 包体前面的同步头，不计入随机的 8 字节载荷。0xAA 0x55 提供密集的 0/1 翻转。
    static let preamble: [UInt8] = [0xAA, 0x55]

    static func bits(for payload: Data) -> [Bool] {
        var bytes = preamble
        bytes.append(contentsOf: payload)
        var bits: [Bool] = []
        bits.reserveCapacity(bytes.count * 8)
        for byte in bytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                bits.append(((byte >> shift) & 0x01) == 1)
            }
        }
        return bits
    }
}

enum PacketFactory {
    static func randomPayload() -> Data {
        var bytes = [UInt8](repeating: 0, count: PacketLayout.payloadBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes)
        }
        var rng = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &rng)
        }
        return Data(bytes)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func data(hex: String) -> Data? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count == PacketLayout.payloadBytes * 2, cleaned.count.isMultiple(of: 2) else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(PacketLayout.payloadBytes)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
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
