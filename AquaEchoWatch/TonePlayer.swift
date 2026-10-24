import AVFoundation
import Foundation

enum TonePlayerError: LocalizedError {
    case empty
    case buffer

    var errorDescription: String? {
        switch self {
        case .empty: return "没有可播放的样本。"
        case .buffer: return "无法创建播放缓冲。"
        }
    }
}

/// 手表端只播放：最大系统音量，不录音、不做反馈。
final class TonePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    private let sampleRate: Double = 48_000
    private let playbackLock = NSLock()
    private var playbackDone: CheckedContinuation<Void, Never>?
    private var playbackVolume: Float = 1
    var onLog: ((String) -> Void)?

    var outputVolume: Float { AVAudioSession.sharedInstance().outputVolume }

    func setPlaybackVolume(_ value: Float) {
        playbackVolume = min(1, max(0, value))
        guard attached else { return }
        // 只保留一级软件增益；混音器保持 1.0，避免音量平方。
        engine.mainMixerNode.outputVolume = 1
        player.volume = playbackVolume
    }

    func preparePlaybackOnly() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)

        if !attached {
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            attached = true
        }
        engine.mainMixerNode.outputVolume = 1
        player.volume = playbackVolume
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
    }

    func play(samples: [Float], leadSamples: Int) async throws -> Date {
        guard !samples.isEmpty else { throw TonePlayerError.empty }
        if !engine.isRunning {
            try preparePlaybackOnly()
        }
        let buffer = try playbackBuffer(sampleCount: samples.count)
        guard let channel = buffer.floatChannelData?[0] else {
            throw TonePlayerError.buffer
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }

        let leadSeconds = Double(max(0, leadSamples)) / sampleRate
        let clock = SendClock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.playbackLock.lock()
            self.playbackDone = continuation
            self.playbackLock.unlock()
            self.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                self.finishPlayback()
            }
            if !self.player.isPlaying {
                self.player.play()
            }
            let latency = AVAudioSession.sharedInstance().outputLatency
            clock.date = Date().addingTimeInterval(latency + leadSeconds)
        }
        return clock.date
    }

    func stop() {
        player.stop()
        engine.stop()
        finishPlayback()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func playbackBuffer(sampleCount: Int) throws -> AVAudioPCMBuffer {
        if let buffer = makePlaybackBuffer(sampleCount: sampleCount) {
            return buffer
        }
        try preparePlaybackOnly()
        if let buffer = makePlaybackBuffer(sampleCount: sampleCount) {
            return buffer
        }
        let running = engine.isRunning ? "是" : "否"
        onLog?("无法创建播放缓冲 sampleRate=48000 count=\(sampleCount) engineRunning=\(running)")
        throw TonePlayerError.buffer
    }

    private func makePlaybackBuffer(sampleCount: Int) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
              buffer.floatChannelData?[0] != nil else {
            return nil
        }
        return buffer
    }

    private func finishPlayback() {
        playbackLock.lock()
        let continuation = playbackDone
        playbackDone = nil
        playbackLock.unlock()
        continuation?.resume()
    }
}

private final class SendClock: @unchecked Sendable {
    var date = Date()
}
