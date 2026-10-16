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

/// 以满幅把 48 kHz 单声道缓冲送到手表扬声器。前导静音之后的时刻记为发送时间。
final class TonePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    private let sampleRate: Double = 48_000
    private let playbackLock = NSLock()
    private var playbackDone: CheckedContinuation<Void, Never>?
    private var playbackVolume: Float = 1

    var outputVolume: Float { AVAudioSession.sharedInstance().outputVolume }

    func setPlaybackVolume(_ value: Float) {
        let clamped = min(1, max(0, value))
        playbackVolume = clamped
        guard attached else { return }
        engine.mainMixerNode.outputVolume = clamped
        player.volume = clamped
    }

    func prepare() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .measurement, policy: .longFormAudio, options: [])
        } catch {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        }
        try session.setActive(true)

        if !attached {
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            attached = true
        }
        engine.mainMixerNode.outputVolume = playbackVolume
        player.volume = playbackVolume
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        finishPlayback()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func play(samples: [Float], leadSamples: Int) async throws -> Date {
        guard !samples.isEmpty else { throw TonePlayerError.empty }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
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
