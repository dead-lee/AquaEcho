import Foundation

/// watercomms 实时通路的卷积码：`Constants.cc = {7, 5, 10}`，码率 1/2。
/// 64 bit 载荷后面再刷 9 个 0，空中是 146 bit。译码去掉这 9 bit。
enum ConvolutionalCode {
    static let messageBitCount = 64
    static let constraintLength = 10
    static let polynomials = [7, 5]
    static let encodedBitCount = 2 * (messageBitCount + constraintLength - 1)

    private struct Parity {
        var first: UInt8
        var second: UInt8
    }

    private static let outputs: [Parity] = {
        let width = 1 << constraintLength
        var table = [Parity](repeating: Parity(first: 0, second: 0), count: width)
        let reversed = polynomials.map { reverseBits(constraintLength, $0) }
        for index in 0..<width {
            var first: UInt8 = 0
            var second: UInt8 = 0
            for (polyIndex, polynomial) in reversed.enumerated() {
                var taps = polynomial
                var input = index
                var output = 0
                for _ in 0..<constraintLength {
                    output ^= (input & 1) & (taps & 1)
                    taps >>= 1
                    input >>= 1
                }
                if polyIndex == 0 {
                    first = UInt8(output)
                } else {
                    second = UInt8(output)
                }
            }
            table[index] = Parity(first: first, second: second)
        }
        return table
    }()

    static func encode(_ bits: [Bool]) -> [Bool] {
        var encoded: [Bool] = []
        encoded.reserveCapacity(2 * (bits.count + constraintLength - 1))
        var state = 0
        for bit in bits {
            append(output(state: state, input: bit ? 1 : 0), to: &encoded)
            state = nextState(state, input: bit ? 1 : 0)
        }
        for _ in 0..<(constraintLength - 1) {
            append(output(state: state, input: 0), to: &encoded)
            state = nextState(state, input: 0)
        }
        return encoded
    }

    static func decode(_ bits: [Bool]) -> [Bool] {
        let stateCount = 1 << (constraintLength - 1)
        var path = [Int](repeating: Int.max, count: stateCount)
        path[0] = 0
        var trellis: [[Int]] = []
        trellis.reserveCapacity(bits.count / 2 + 1)
        var index = 0
        while index < bits.count {
            let first = bits[index]
            let second = index + 1 < bits.count ? bits[index + 1] : false
            index += 2
            var nextPath = [Int](repeating: 0, count: stateCount)
            var column = [Int](repeating: 0, count: stateCount)
            let lowMask = (1 << (constraintLength - 2)) - 1
            for state in 0..<stateCount {
                let shifted = (state & lowMask) << 1
                let firstMetric = metric(path: path, source: shifted, target: state, first: first, second: second)
                let secondMetric = metric(path: path, source: shifted | 1, target: state, first: first, second: second)
                if firstMetric <= secondMetric {
                    nextPath[state] = firstMetric
                    column[state] = shifted
                } else {
                    nextPath[state] = secondMetric
                    column[state] = shifted | 1
                }
            }
            path = nextPath
            trellis.append(column)
        }

        var state = 0
        var best = Int.max
        for candidate in path.indices where path[candidate] < best {
            best = path[candidate]
            state = candidate
        }
        var decoded: [Bool] = []
        decoded.reserveCapacity(trellis.count)
        for column in trellis.reversed() {
            decoded.append(((state >> (constraintLength - 2)) & 1) == 1)
            state = column[state]
        }
        decoded.reverse()
        let flush = constraintLength - 1
        guard decoded.count >= flush else { return [] }
        return Array(decoded.dropLast(flush))
    }

    private static func metric(path: [Int], source: Int, target: Int, first: Bool, second: Bool) -> Int {
        let previous = path[source]
        guard previous < Int.max else { return Int.max }
        let input = (target >> (constraintLength - 2)) & 1
        let expected = output(state: source, input: input)
        var distance = previous
        if (first ? 1 : 0) != Int(expected.first) { distance += 1 }
        if (second ? 1 : 0) != Int(expected.second) { distance += 1 }
        return distance
    }

    private static func output(state: Int, input: Int) -> Parity {
        outputs[state | (input << (constraintLength - 1))]
    }

    private static func nextState(_ state: Int, input: Int) -> Int {
        (state >> 1) | (input << (constraintLength - 2))
    }

    private static func append(_ parity: Parity, to bits: inout [Bool]) {
        bits.append(parity.first == 1)
        bits.append(parity.second == 1)
    }

    private static func reverseBits(_ width: Int, _ value: Int) -> Int {
        var input = value
        var output = 0
        var remaining = width
        while remaining > 0 {
            remaining -= 1
            output = (output << 1) + (input & 1)
            input >>= 1
        }
        return output
    }
}
