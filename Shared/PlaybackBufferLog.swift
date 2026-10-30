import Foundation

/// 手表播放缓冲的副本。只保存交给播放器的样本，不打开麦克风。
final class PlaybackBufferLog {
    static let filePrefix = "AquaEcho_WatchTx_"
    static let sampleRate = 48_000.0
    /// 调度停顿超过这个长度时不再按真实时间补 0，避免一次卡顿写出巨大文件。
    static let maxGapSamples = 96_000

    private(set) var samples: [Float] = []
    private var previousEnd: Date?

    var isEmpty: Bool { samples.isEmpty }

    /// `startedAt` 是这一缓冲开始出声的时刻。与上一包结束之间的空隙补 0。
    func append(_ buffer: [Float], startedAt: Date, sampleRate: Double = sampleRate) {
        if let previousEnd {
            let gap = startedAt.timeIntervalSince(previousEnd)
            if gap > 0 {
                let count = min(Int((gap * sampleRate).rounded()), Self.maxGapSamples)
                if count > 0 {
                    samples.append(contentsOf: repeatElement(0, count: count))
                }
            }
        }
        samples.append(contentsOf: buffer)
        previousEnd = startedAt.addingTimeInterval(Double(buffer.count) / sampleRate)
    }

    func write(directory: URL, when: Date = Date()) throws -> URL? {
        guard !samples.isEmpty else { return nil }
        return try FloatWav.write(
            samples: samples,
            sampleRate: Self.sampleRate,
            directory: directory,
            prefix: Self.filePrefix,
            when: when
        )
    }

    static func removePreviousFiles(in directory: URL, keeping kept: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.lastPathComponent.hasPrefix(filePrefix) && url.lastPathComponent != kept.lastPathComponent {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 只接受本功能写出的文件名，避免把传输元数据里的路径写进 Documents。
    static func acceptedFileName(_ name: String) -> String? {
        guard !name.contains("/"), !name.contains(".."),
              name.hasPrefix(filePrefix), name.hasSuffix(".wav") else { return nil }
        return name
    }
}
