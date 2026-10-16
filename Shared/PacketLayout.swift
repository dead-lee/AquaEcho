import Foundation
import Security

enum PacketLayout {
    static let payloadBytes = 8
    static let bitCount = 64

    static func frequencyCode(_ hz: Double) -> Int {
        Int((hz / 50).rounded())
    }

    /// 64 bit，从高位到低位：低频 10、高频 10、序号 3、随机 33、扩展汉明校验 8。没有前导。
    static func encode(lowHz: Double, highHz: Double, sequence: Int, random: UInt64? = nil) -> Data {
        let low = UInt64(frequencyCode(lowHz) & 0x3FF)
        let high = UInt64(frequencyCode(highHz) & 0x3FF)
        let seq = UInt64(sequence & 0x7)
        let noise = (random ?? randomBits()) & ((UInt64(1) << 33) - 1)
        var word: UInt64 = 0
        word |= low << 54
        word |= high << 44
        word |= seq << 41
        word |= noise << 8
        let sum = ExtendedHamming.checksum(data56: word >> 8)
        word |= UInt64(sum)
        return data(from: word)
    }

    static func word(from data: Data) -> UInt64 {
        var word: UInt64 = 0
        for byte in data.prefix(payloadBytes) {
            word = (word << 8) | UInt64(byte)
        }
        if data.count < payloadBytes {
            word <<= UInt64((payloadBytes - data.count) * 8)
        }
        return word
    }

    static func data(from word: UInt64) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(payloadBytes)
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((word >> shift) & 0xFF))
        }
        return Data(bytes)
    }

    struct Fields {
        var lowHz: Double
        var highHz: Double
        var sequence: Int
        var corrected: Bool
        var payload: Data
    }

    /// 先纠正最多 1 bit，再按位序读出低频、高频和序号。
    static func decode(_ data: Data) -> Fields {
        let corrected = ExtendedHamming.correct(word: word(from: data))
        let word = corrected.word
        let lowCode = Int((word >> 54) & 0x3FF)
        let highCode = Int((word >> 44) & 0x3FF)
        let sequence = Int((word >> 41) & 0x7)
        return Fields(
            lowHz: Double(lowCode * 50),
            highHz: Double(highCode * 50),
            sequence: sequence,
            corrected: corrected.corrected,
            payload: PacketLayout.data(from: word)
        )
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

    static func matchKey(lowHz: Double, highHz: Double, sequence: Int) -> MatchKey {
        MatchKey(
            lowCode: frequencyCode(lowHz),
            highCode: frequencyCode(highHz),
            sequence: sequence & 0x7
        )
    }

    private static func randomBits() -> UInt64 {
        var bytes = [UInt8](repeating: 0, count: 5)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max, using: &rng)
            }
        }
        var value: UInt64 = 0
        for byte in bytes {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}

struct MatchKey: Hashable {
    var lowCode: Int
    var highCode: Int
    var sequence: Int
}

enum PacketFactory {
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
