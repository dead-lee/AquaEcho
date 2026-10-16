import Foundation

/// 覆盖 56 bit 数据的扩展汉明码，校验 8 bit，能纠正 1 bit。
/// 数据比特按从低到高的顺序放进汉明位置里不是 2 的幂的那些位置；7 个汉明校验位加 1 个整体偶校验。
enum ExtendedHamming {
    enum Status {
        case clean
        case corrected
        case uncorrectable
    }

    struct Result {
        var word: UInt64
        var status: Status

        var corrected: Bool { status == .corrected }
    }

    /// 56 个数据比特对应的汉明位置。位置从 1 起，跳过 2 的幂。
    static let dataPositions: [Int] = {
        var positions: [Int] = []
        var number = 1
        while positions.count < 56 {
            if number & (number - 1) != 0 {
                positions.append(number)
            }
            number += 1
        }
        return positions
    }()

    private static let dataIndexByPosition: [Int: Int] = {
        var map: [Int: Int] = [:]
        for (index, position) in dataPositions.enumerated() {
            map[position] = index
        }
        return map
    }()

    /// `data56` 只用低 56 bit。返回写入 bit 7–0 的 8 bit 校验。
    static func checksum(data56: UInt64) -> UInt8 {
        let data = data56 & ((UInt64(1) << 56) - 1)
        var ones = Set<Int>()
        for index in 0..<56 where (data >> index) & 1 == 1 {
            ones.insert(dataPositions[index])
        }
        var check: UInt8 = 0
        for power in 0..<7 {
            let parityPos = 1 << power
            var xor = false
            for position in ones where position & parityPos != 0 {
                xor.toggle()
            }
            if xor {
                check |= UInt8(1 << power)
                ones.insert(parityPos)
            }
        }
        if ones.count % 2 != 0 {
            check |= 0x80
        }
        return check
    }

    /// `word` 的 bit 63–8 是数据，bit 7–0 是校验。
    static func correct(word: UInt64) -> Result {
        var data = (word >> 8) & ((UInt64(1) << 56) - 1)
        var check = UInt8(word & 0xFF)
        let placed = placedOnes(data56: data, checksumLow7: check & 0x7F)
        var syndrome = 0
        for power in 0..<7 {
            let parityPos = 1 << power
            var xor = false
            for position in placed where position & parityPos != 0 {
                xor.toggle()
            }
            if xor {
                syndrome |= parityPos
            }
        }
        let overallOdd = (data.nonzeroBitCount + check.nonzeroBitCount) % 2 != 0
        if syndrome == 0 && !overallOdd {
            return Result(word: word, status: .clean)
        }
        if syndrome == 0 && overallOdd {
            check ^= 0x80
            return Result(word: pack(data: data, check: check), status: .corrected)
        }
        if syndrome != 0 && overallOdd {
            if let dataIndex = dataIndexByPosition[syndrome] {
                data ^= UInt64(1) << dataIndex
                return Result(word: pack(data: data, check: check), status: .corrected)
            }
            if syndrome > 0, syndrome & (syndrome - 1) == 0, syndrome <= 64 {
                var power = 0
                var value = syndrome
                while value > 1 {
                    value >>= 1
                    power += 1
                }
                check ^= UInt8(1 << power)
                return Result(word: pack(data: data, check: check), status: .corrected)
            }
        }
        return Result(word: word, status: .uncorrectable)
    }

    private static func placedOnes(data56: UInt64, checksumLow7: UInt8) -> Set<Int> {
        var ones = Set<Int>()
        for index in 0..<56 where (data56 >> index) & 1 == 1 {
            ones.insert(dataPositions[index])
        }
        for power in 0..<7 where checksumLow7 & UInt8(1 << power) != 0 {
            ones.insert(1 << power)
        }
        return ones
    }

    private static func pack(data: UInt64, check: UInt8) -> UInt64 {
        (data << 8) | UInt64(check)
    }
}
