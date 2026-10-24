import AVFoundation
import Foundation
import SwiftUI

/// 手表端扫描发送器：只播放，不录音、不做反馈、不握手。
/// 序列固定为“集合列表 × 每组包数”，每包 = 标记音 + 保护间隔 + OFDM 数据。
@MainActor
final class WatchScanModel: ObservableObject {
    @Published private(set) var status = "等待手机同步场景"
    @Published private(set) var isRunning = false
    @Published private(set) var progressText = ""
    @Published private(set) var runLabel = "未同步场景"
    @Published private(set) var outputVolume: Float = 0
    @Published private(set) var foregroundRunning = false
    @Published private(set) var config = ScanRunConfig()

    private let player = TonePlayer()
    private let link = WatchLink()
    let foreground = ForegroundSession()
    private var task: Task<Void, Never>?
    private var stopRequested = false
    private var pendingLogs: [String] = []
    private var holdLogSync = false

    init() {
        player.onLog = { [weak self] message in self?.log(message) }
        foreground.onEvent = { [weak self] message in
            guard let self else { return }
            self.log(message)
            self.foregroundRunning = self.foreground.running
        }
        foreground.onStopSound = { [weak self] reason in
            if reason.hasPrefix("resignedFrontmost") {
                self?.log("按数码表冠离开，停止扫描")
                self?.stop()
            }
        }
        link.onEnvelope = { [weak self] envelope in
            Task { @MainActor in self?.handle(envelope) }
        }
        link.onReachable = { [weak self] value in
            Task { @MainActor in
                guard value else { return }
                self?.flushLogs()
            }
        }
        link.activate()
        refreshOutputVolume()

        WatchActivation.onDidBecomeActive = { [weak self] in
            self?.foreground.setAllowedToStart(true)
            self?.foreground.ensureRunning()
            self?.flushLogs(force: true)
        }
        WatchActivation.onWillResignActive = { [weak self] in
            self?.foreground.setAllowedToStart(false)
            self?.flushLogs(force: true)
        }
        WatchActivation.onDidEnterBackground = { [weak self] in
            self?.flushLogs(force: true)
        }

        log("手表扫描端启动 构建 \(AppBuild.number)")
    }

    var packetsPerSet: Int { max(1, min(200, config.packetsPerSet)) }
    var sets: [SpectralSet] { config.activeSets }
    var totalPackets: Int { sets.count * packetsPerSet }

    func start() {
        guard !isRunning else { return }
        stopRequested = false
        isRunning = true
        status = "准备播放"
        progressText = "0/\(totalPackets)"
        refreshOutputVolume()
        foreground.setAllowedToStart(true)
        foreground.ensureRunning()

        do {
            try player.preparePlaybackOnly()
        } catch {
            status = "播放器启动失败：\(error.localizedDescription)"
            log("错误 播放器启动失败 \(error.localizedDescription)")
            isRunning = false
            return
        }

        log("开始扫描 \(config.label) 集合=\(sets.map(\.id).joined(separator: ",")) 每组=\(packetsPerSet) 总包=\(totalPackets) 系统音量=\(String(format: "%.2f", outputVolume))")
        task = Task { await run() }
    }

    func stop() {
        guard isRunning else { return }
        stopRequested = true
        task?.cancel()
        task = nil
        player.stop()
        foreground.endBecauseUserStoppedOrLeft()
        foregroundRunning = false
        isRunning = false
        status = "已停止"
        log("停止扫描")
    }

    /// 扫描完成后保持前台；用户主动结束，或按数码表冠离开时调用。
    func endForeground() {
        foreground.endBecauseUserStoppedOrLeft()
        foregroundRunning = false
        if !isRunning { status = "已结束前台保持" }
        log("结束前台保持")
    }

    func noteScenePhase(_ phase: ScenePhase) {
        foreground.noteScenePhase(phase)
        if phase == .active {
            foreground.setAllowedToStart(true)
            foreground.ensureRunning()
        }
    }

    func refreshOutputVolume() {
        outputVolume = AVAudioSession.sharedInstance().outputVolume
    }

    private func run() async {
        holdLogSync = true
        defer {
            holdLogSync = false
            flushLogs()
        }

        let packets = packetsPerSet
        let activeSets = sets
        if activeSets.isEmpty {
            status = "没有可发送的集合"
            isRunning = false
            return
        }

        do {
            status = "3 秒后开始"
            try await Task.sleep(nanoseconds: 3_000_000_000)
            try Task.checkCancellation()
            if stopRequested { return }

            var sent = 0
            for set in activeSets {
                for index in 0..<packets {
                    if stopRequested || Task.isCancelled { return }
                    let payload = ScanPayload.make(setID: set.id, packetIndex: index)
                    let frame = ScanProtocol.makeFrame(payload: payload, set: set)
                    let airtime = Double(frame.count) / ScanProtocol.sampleRate * 1_000
                    let date = try await player.play(samples: frame, leadSamples: 0)
                    sent += 1
                    progressText = "\(set.id) \(index + 1)/\(packets) · \(sent)/\(activeSets.count * packets)"
                    status = "发送 \(set.id) 包 \(index + 1)/\(packets)"
                    log(String(
                        format: "集合=%@ 包=%d 期望=%@ airtime=%.1fms 发送时间=%@",
                        locale: Locale(identifier: "en_US_POSIX"),
                        set.id, index, ScanPayload.hex(payload), airtime, RunLog.timestamp(date)
                    ))
                }
            }

            status = "扫描完成（前台保持中）"
            progressText = "\(sent)/\(activeSets.count * packets)"
            log("扫描完成 共 \(sent) 包")
            link.send(WCEnvelope(kind: .finished))
        } catch is CancellationError {
            status = "已停止"
            log("扫描被取消")
        } catch {
            status = "错误：\(error.localizedDescription)"
            log("错误 \(error.localizedDescription)")
        }

        player.stop()
        isRunning = false
        task = nil
        foregroundRunning = foreground.running
        refreshOutputVolume()
    }

    private func handle(_ envelope: WCEnvelope) {
        if (envelope.kind == .config || envelope.kind == .startScan), let scan = envelope.scanConfig {
            config = scan.normalized
            runLabel = config.label
            log("收到手机\(envelope.kind == .startScan ? "开始指令" : "配置") \(config.label)")
            if envelope.kind == .startScan {
                start()
            } else {
                status = "已同步：\(config.scenario.title)"
            }
            return
        }
        if envelope.kind == .startScan {
            start()
            return
        }
        if envelope.kind == .config || envelope.kind == .finished {
            return
        }
        if envelope.kind == .log, let line = envelope.log {
            // 手表不消费手机日志，忽略即可。
            _ = line
        }
    }

    private func log(_ message: String) {
        let line = "[Watch][Scan] \(message)"
        RunLog.shared.append(line)
        pendingLogs.append(line)
        guard !holdLogSync else { return }
        flushLogs()
    }

    private func flushLogs(force: Bool = false) {
        guard (force || !holdLogSync), !pendingLogs.isEmpty else { return }
        let batch = pendingLogs.joined(separator: "\n")
        var remaining = batch[...]
        // 单条 WatchConnectivity 消息有大小上限；按约 8 KB 分块发送。
        while !remaining.isEmpty {
            let chunk = String(remaining.prefix(8_000))
            guard link.send(WCEnvelope(kind: .log, log: chunk)) else {
                return
            }
            remaining = remaining.dropFirst(chunk.count)
        }
        pendingLogs.removeAll()
    }
}

@MainActor
enum WatchActivation {
    static var onDidBecomeActive: (() -> Void)?
    static var onWillResignActive: (() -> Void)?
    static var onDidEnterBackground: (() -> Void)?
}
