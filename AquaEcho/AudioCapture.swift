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
final class AudioCapture {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var storage: [Float] = []
    private var startedAt: Date?
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
        storage.removeAll(keepingCapacity: true)
        startedAt = nil
        sampleRate = format.sampleRate
        lock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, time in
            self?.append(buffer, hostTime: time.hostTime)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engine(error.localizedDescription)
        }
        isRunning = true
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func snapshot() -> CaptureBuffer {
        lock.lock()
        defer { lock.unlock() }
        return CaptureBuffer(
            samples: storage,
            sampleRate: sampleRate,
            startedAt: startedAt ?? Date()
        )
    }

    private func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
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
        storage.append(contentsOf: chunk)
        lock.unlock()
    }

    private func date(fromHostTime hostTime: UInt64) -> Date {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let scale = Double(info.numer) / Double(info.denom) / 1_000_000_000
        let delta = (Double(hostTime) - Double(mach_absolute_time())) * scale
        return Date().addingTimeInterval(delta)
    }
}
