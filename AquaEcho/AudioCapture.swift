import AVFoundation
import Foundation

enum AudioCaptureError: LocalizedError {
    case microphoneUnavailable
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            return "麦克风还没有准备好。"
        case .engine(let message):
            return message
        }
    }
}

/// 以 measurement 模式录音，关闭自动增益，尽量保持 48 kHz。
/// 回调拿到的是当前这一小段采样，调用方自己保留滑动窗口。
final class AudioCapture {
    var onSamples: ((_ samples: [Float], _ at: Date, _ sampleRate: Double) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playerReady = false
    private let lock = NSLock()
    private var startedAt: Date?
    private var sampleCount = 0
    private var sampleRate: Double = 48_000
    private(set) var isRunning = false

    static func requestPermission() async -> Bool {
        let application = AVAudioApplication.shared
        switch application.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.microphoneUnavailable
        }

        lock.lock()
        startedAt = nil
        sampleCount = 0
        sampleRate = format.sampleRate
        lock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, time in
            self?.deliver(buffer, hostTime: time.hostTime)
        }
        if !playerReady {
            let playback = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playback)
            player.volume = 1
            playerReady = true
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engine(error.localizedDescription)
        }
        isRunning = true
        if !player.isPlaying {
            player.play()
        }
    }

    func play(_ samples: [Float]) async throws {
        guard playerReady, !samples.isEmpty else { throw AudioCaptureError.engine("反馈播放器还没有准备好。") }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw AudioCaptureError.engine("无法创建反馈缓冲。")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                continuation.resume()
            }
            if !self.player.isPlaying {
                self.player.play()
            }
        }
    }

    func stop() {
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func deliver(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var chunk: [Float] = []
        chunk.reserveCapacity(frames)
        if let channel = buffer.floatChannelData?[0] {
            chunk.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
        } else if let channel = buffer.int16ChannelData?[0] {
            for index in 0..<frames {
                chunk.append(Float(channel[index]) / Float(Int16.max))
            }
        } else {
            return
        }

        lock.lock()
        if startedAt == nil {
            startedAt = date(fromHostTime: hostTime)
            if buffer.format.sampleRate > 0 {
                sampleRate = buffer.format.sampleRate
            }
        }
        let origin = startedAt ?? Date()
        let rate = sampleRate
        let at = origin.addingTimeInterval(Double(sampleCount) / rate)
        sampleCount += chunk.count
        lock.unlock()
        onSamples?(chunk, at, rate)
    }

    private func date(fromHostTime hostTime: UInt64) -> Date {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let scale = Double(info.numer) / Double(info.denom) / 1_000_000_000
        let delta = (Double(hostTime) - Double(mach_absolute_time())) * scale
        return Date().addingTimeInterval(delta)
    }
}
