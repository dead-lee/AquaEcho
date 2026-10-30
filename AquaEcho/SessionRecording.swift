import Foundation

enum SessionRecording {
    /// 把这次测试的原始麦克风采样写成 32-bit float WAV。文件名 `AquaEcho_Recording_yyyyMMdd_HHmmss.wav`。
    static func write(samples: [Float], sampleRate: Double, directory: URL? = nil, prefix: String = "AquaEcho_Recording_") throws -> URL {
        let folder = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return try FloatWav.write(samples: samples, sampleRate: sampleRate, directory: folder, prefix: prefix)
    }
}
