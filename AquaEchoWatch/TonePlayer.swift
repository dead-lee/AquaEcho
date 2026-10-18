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
    private var inputTap = false
    private var recorded: SampleBox?
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
            try session.setCategory(.playAndRecord, mode: .measurement, policy: .longFormAudio, options: [])
        } catch {
            try session.setCategory(.playAndRecord, mode: .default, policy: .longFormAudio, options: [])
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

    func beginRecording() throws -> Double {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TonePlayerError.buffer
        }
        recorded = SampleBox()
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channel = buffer.floatChannelData?[0] else { return }
            self?.recorded?.append(Array(UnsafeBufferPointer(start: channel, count: frames)))
        }
        inputTap = true
        if !engine.isRunning {
            try engine.start()
        }
        return format.sampleRate
    }

    func endRecording() -> [Float] {
        let samples = recorded?.samples ?? []
        recorded = nil
        finishRecording()
        return samples
    }

    func stop() {
        finishRecording()
        recorded = nil
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

    private func finishRecording() {
        guard inputTap else { return }
        inputTap = false
        engine.inputNode.removeTap(onBus: 0)
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

private final class SampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Float] = []

    func append(_ samples: [Float]) {
        lock.lock()
        stored.append(contentsOf: samples)
        lock.unlock()
    }

    var samples: [Float] {
        lock.lock()
        let copy = stored
        lock.unlock()
        return copy
    }
}
