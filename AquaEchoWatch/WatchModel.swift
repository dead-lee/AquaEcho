import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class WatchModel: ObservableObject {
    @Published var config: TestConfig
    @Published var reachable = false
    @Published var isRunning = false
    @Published var status = "等待 iPhone 开始"
    @Published var outputVolume: Float = 0
    @Published var foregroundStatus = "正在申请前台"

    private let link = WatchLink()
    private let player = TonePlayer()
    let foreground = ForegroundSession()
    private var stopRequested = false
    private var didStop = false
    private var playing = false
    private var pendingLogs: [String] = []
    private var flushingLogs = false
    /// 发送循环进行中时为 true：日志只进本地文件和 pendingLogs，不经 Watch Connectivity 发出。
    private var holdLogSync = false

    init() {
        config = ConfigStore.load()
        foreground.onEvent = { [weak self] message in
            self?.log(message)
            self?.foregroundStatus = self?.foreground.status ?? message
        }
        foreground.onStopSound = { [weak self] in
            self?.stop()
        }
        link.onEnvelope = { [weak self] envelope in
            Task { @MainActor in
                self?.handle(envelope)
            }
        }
        link.onReachable = { [weak self] value in
            Task { @MainActor in
                self?.reachable = value
                self?.flushLogs()
            }
        }
        link.activate()
        outputVolume = player.outputVolume
        log("手表端启动")
        WatchActivation.onDidBecomeActive = { [weak self] in
            self?.startExtendedRuntimeAfterBecomeActive()
        }
    }

    func startExtendedRuntimeAfterBecomeActive() {
        log("延长运行已在 applicationDidBecomeActive 后启动")
        foreground.startIfNeeded()
        foregroundStatus = foreground.status
    }

    func noteScenePhase(_ phase: ScenePhase) {
        foreground.noteScenePhase(phase)
        foregroundStatus = foreground.status
    }

    func requestStart() {
        guard !isRunning else { return }
        link.send(WCEnvelope(kind: .requestStart, config: config, packet: nil, packets: nil, progress: nil))
        status = reachable ? "已请 iPhone 开始录音" : "iPhone 未连接"
    }

    func stop() {
        guard !didStop else { return }
        didStop = true
        stopRequested = true
        status = "已停止"
        log("停止发送")
        player.stop()
        foreground.endBecauseUserStoppedOrLeft()
        foregroundStatus = foreground.status
    }

    private func handle(_ envelope: WCEnvelope) {
        switch envelope.kind {
        case .config:
            if let config = envelope.config {
                self.config = config.normalized
                ConfigStore.save(self.config)
                status = "已收到新配置"
            }
        case .start:
            if let config = envelope.config {
                self.config = config.normalized
                ConfigStore.save(self.config)
            }
            guard !playing else { return }
            Task { await run() }
        case .stop:
            stop()
        case .requestStart, .progress, .packet, .finished, .log:
            break
        }
    }

    private func run() async {
        holdLogSync = true
        defer {
            holdLogSync = false
            flushLogs()
            if !pendingLogs.isEmpty {
                retryLogFlush()
            }
        }
        playing = true
        isRunning = true
        stopRequested = false
        didStop = false
        let config = self.config.normalized
        var sent: [SentPacket] = []
        do {
            try player.prepare()
            let volume = AVAudioSession.sharedInstance().outputVolume
            outputVolume = volume
            log(String(format: "音量 outputVolume=%.2f", locale: Locale(identifier: "en_US_POSIX"), volume))
            if volume < 0.95 {
                status = "音量不足，请旋转数码表冠调到最大"
            }
            foreground.ensureRunning()
            log("开始发送 \(config.mode.title)，\(config.plannedPairs().count) 组，重复 \(config.repeats) 次")
            try await Task.sleep(nanoseconds: 400_000_000)
            var sequence = 0
            var lastPair = ""
            let pairs = config.plannedPairs()
            for pair in pairs {
                if stopRequested { break }
                if pair.label != lastPair {
                    lastPair = pair.label
                    log("当前频率对 \(pair.label)")
                }
                for repeatIndex in 0..<config.repeats {
                    if stopRequested { break }
                    sequence += 1
                    let payload = PacketFactory.randomPayload()
                    let rendered = try render(pair: pair, payload: payload, config: config)
                    log("编码完成 \(config.mode.title) \(pair.label) \(rendered.samples.count) 样本 载荷 \(PacketFactory.hex(payload))")
                    status = "\(sequence) · \(pair.label)"
                    link.send(WCEnvelope(
                        kind: .progress,
                        config: nil,
                        packet: nil,
                        packets: nil,
                        progress: "正在发送 \(pair.label)（\(repeatIndex + 1)/\(config.repeats)）"
                    ))
                    let sendDate = try await player.play(samples: rendered.samples, leadSamples: rendered.leadSamples)
                    log("发送时间 \(RunLog.timestamp(sendDate)) 序号 \(sequence) \(pair.label)")
                    let packet = SentPacket(
                        sequence: sequence,
                        repeatIndex: repeatIndex,
                        lowHz: pair.lowHz,
                        highHz: pair.highHz,
                        payloadHex: PacketFactory.hex(payload),
                        watchSendTimestamp: sendDate.timeIntervalSince1970
                    )
                    sent.append(packet)
                    link.send(WCEnvelope(kind: .packet, config: nil, packet: packet, packets: nil, progress: nil))
                }
            }
            if !stopRequested {
                status = "发送完成"
                log("发送完成，共 \(sent.count) 包")
            }
        } catch {
            status = error.localizedDescription
            log("错误 \(error.localizedDescription)")
        }
        player.stop()
        link.send(WCEnvelope(kind: .finished, config: config, packet: nil, packets: sent, progress: nil))
        isRunning = false
        playing = false
        outputVolume = player.outputVolume
    }

    private func log(_ message: String) {
        let line = "[Watch] \(message)"
        RunLog.shared.append(line)
        pendingLogs.append(line)
        foregroundStatus = foreground.status
        guard !holdLogSync else { return }
        flushLogs()
        if !pendingLogs.isEmpty {
            retryLogFlush()
        }
    }

    private func flushLogs() {
        guard !holdLogSync, !pendingLogs.isEmpty else { return }
        let batch = pendingLogs.joined(separator: "\n")
        if link.send(WCEnvelope(kind: .log, log: batch)) {
            pendingLogs = []
        }
    }

    private func retryLogFlush() {
        guard !holdLogSync, !flushingLogs else { return }
        flushingLogs = true
        Task { @MainActor in
            for _ in 0..<20 {
                if holdLogSync || pendingLogs.isEmpty { break }
                try? await Task.sleep(nanoseconds: 300_000_000)
                if holdLogSync { break }
                flushLogs()
            }
            flushingLogs = false
            if !holdLogSync, !pendingLogs.isEmpty {
                retryLogFlush()
            }
        }
    }

    private func render(pair: PlannedPair, payload: Data, config: TestConfig) throws -> (samples: [Float], leadSamples: Int) {
        let leadSamples = Int((config.leadSilenceMs / 1_000 * config.sampleRate).rounded())
        switch config.mode {
        case .cpfsk:
            let samples = CPFSKSynth.playback(
                bits: PacketLayout.bits(for: payload),
                f0: pair.lowHz,
                f1: pair.highHz,
                symbolSeconds: config.symbolDurationMs / 1_000,
                sampleRate: config.sampleRate,
                leadMs: config.leadSilenceMs,
                trailMs: config.trailSilenceMs
            )
            return (samples, leadSamples)
        case .ggwave:
            guard let tone = GGWaveBridge.encode(
                payload: payload,
                startHz: pair.lowHz,
                protocol: config.ggwaveProtocol,
                volume: config.ggwaveVolume
            ) else {
                throw TonePlayerError.empty
            }
            let samples = CPFSKSynth.padded(
                tone,
                leadMs: config.leadSilenceMs,
                trailMs: config.trailSilenceMs,
                sampleRate: config.sampleRate
            )
            return (samples, leadSamples)
        }
    }
}

@MainActor
enum WatchActivation {
    static var onDidBecomeActive: (() -> Void)?
}
