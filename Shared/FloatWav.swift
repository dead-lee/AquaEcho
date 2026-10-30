import Foundation

/// 48 kHz 单声道 32-bit float WAV。手机麦克风录音和手表播放缓冲用同一种写法。
enum FloatWav {
    static func write(samples: [Float], sampleRate: Double, directory: URL, prefix: String, when: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let url = directory.appendingPathComponent("\(prefix)\(formatter.string(from: when)).wav")
        let rate = UInt32(sampleRate.rounded())
        let dataBytes = samples.count * MemoryLayout<Float>.size
        var data = Data()
        data.reserveCapacity(44 + dataBytes)
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        data.append(uint32: UInt32(36 + dataBytes))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        data.append(uint32: 16)
        data.append(uint16: 3)
        data.append(uint16: 1)
        data.append(uint32: rate)
        data.append(uint32: rate * 4)
        data.append(uint16: 4)
        data.append(uint16: 32)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        data.append(uint32: UInt32(dataBytes))
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            data.append(Data(buffer: UnsafeBufferPointer(start: base, count: buffer.count)))
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    static func readSamples(from url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count >= 44 else { return [] }
        return data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func append(uint32 value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
