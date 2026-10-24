import Foundation

enum SessionRecording {
    /// 把这次测试的原始麦克风采样写成 32-bit float WAV。文件名 `AquaEcho_Recording_yyyyMMdd_HHmmss.wav`。
    static func write(samples: [Float], sampleRate: Double, directory: URL? = nil, prefix: String = "AquaEcho_Recording_") throws -> URL {
        let folder = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let url = folder.appendingPathComponent("\(prefix)\(formatter.string(from: Date())).wav")
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
