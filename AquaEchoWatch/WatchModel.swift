import AVFoundation
import Foundation
import HealthKit
import SwiftUI

/// 手表端扫描发送器：workout session 负责保活，音频只负责发波。
/// 序列固定为“集合列表 × 每组包数”，每包 = 标记音 + 保护间隔 + OFDM 数据。
@MainActor
final class WatchModel: ObservableObject {
    @Published private(set) var status = "等待手机同步场景"
    @Published private(set) var reachable = false
    @Published private(set) var isRunning = false
    @Published private(set) var progressText = ""
    @Published private(set) var runLabel = "未同步场景"
    @Published var outputVolume: Float = 0
    @Published private(set) var foregroundRunning = false
    @Published var foregroundStatus = "未开始"
    @Published var volumeBlocked = false
    @Published private(set) var config = ScanRunConfig()

    private let player = TonePlayer()
    private let link = WatchLink()
    private let workout = WorkoutKeeper()
    private var task: Task<Void, Never>?
    private var stopRequested = false
    private var pendingLogs: [String] = []
    private var holdLogSync = false
    private var volumeObservation: NSKeyValueObservation?
    private var volumeTask: Task<Void, Never>?

    init() {
        player.onLog = { [weak self] message in self?.log(message) }
        workout.onEvent = { [weak self] message in
            guard let self else { return }
            self.log(message)
            self.foregroundRunning = self.workout.running
            self.foregroundStatus = self.workout.status
        }
        workout.onReady = { [weak self] in
            guard let self else { return }
            self.foregroundRunning = true
            self.foregroundStatus = self.workout.status
            self.log("workout 已 running，通知手机 ready")
            self.link.send(WCEnvelope(kind: .ready))
        }
        workout.onEnded = { [weak self] in
            guard let self else { return }
            self.foregroundRunning = false
            self.foregroundStatus = self.workout.status
            self.log("workout 已结束")
            self.link.send(WCEnvelope(kind: .workoutEnded))
        }

        link.onEnvelope = { [weak self] envelope in
            Task { @MainActor in self?.handle(envelope) }
        }
        link.onReachable = { [weak self] value in
            Task { @MainActor in
                self?.reachable = value
                guard value else { return }
                self?.flushLogs()
                if self?.workout.running == true {
                    self?.link.send(WCEnvelope(kind: .ready))
                }
            }
        }
        link.activate()
        player.setPlaybackVolume(1)
        refreshOutputVolume()

        WatchActivation.onDidBecomeActive = { [weak self] in
            self?.log("AppDelegate applicationDidBecomeActive")
            self?.flushLogs(force: true)
            Task { @MainActor in await self?.workout.startIfNeeded(source: "appDidBecomeActive") }
        }
        WatchActivation.onWillResignActive = { [weak self] in
            self?.log("applicationWillResignActive")
            self?.flushLogs(force: true)
        }
        WatchActivation.onDidEnterBackground = { [weak self] in
            self?.handleEnterBackground()
        }
        WatchActivation.onWorkoutConfiguration = { [weak self] _ in
            Task { @MainActor in
                self?.log("收到手机 startWatchApp 的 workout 配置")
                await self?.workout.startIfNeeded(source: "workoutConfiguration")
            }
        }

        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            Task { @MainActor in
                guard let self else { return }
                self.outputVolume = change.newValue ?? AVAudioSession.sharedInstance().outputVolume
            }
        }
        refreshOutputVolume()
        volumeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.refreshOutputVolume()
            }
        }

        log("手表扫描端启动 构建 \(AppBuild.number)")
        if WatchActivation.pendingWorkoutConfiguration != nil {
            WatchActivation.pendingWorkoutConfiguration = nil
            Task { @MainActor in await self.workout.startIfNeeded(source: "pendingWorkout") }
        }
    }

    var packetsPerSet: Int { max(1, min(200, config.packetsPerSet)) }
    var sets: [SpectralSet] { config.activeSets }
    var totalPackets: Int { sets.count * packetsPerSet }

    func start() {
        guard !isRunning else { return }
        refreshOutputVolume()
        if outputVolume < 0.99 {
            volumeBlocked = true
            status = "系统音量 \(Int((outputVolume * 100).rounded()))%；请用表冠调整系统音量"
            log("音量提示：系统音量=\(String(format: "%.2f", outputVolume))；请用表冠调整系统音量，仍开始")
        } else {
            volumeBlocked = false
        }
        stopRequested = false
        isRunning = true
        status = "准备工作"
        progressText = "0/\(totalPackets)"

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.workout.startIfNeeded(source: "phoneStart")
            for _ in 0..<30 {
                if self.workout.running { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard self.workout.running else {
                self.isRunning = false
                self.status = "workout 未运行，未开始"
                self.log("错误 workout 未运行，不能开始扫描")
                return
            }
            do {
                try self.player.preparePlaybackOnly()
            } catch {
                self.status = "播放器启动失败：\(error.localizedDescription)"
                self.log("错误 播放器启动失败 \(error.localizedDescription)")
                self.isRunning = false
                return
            }
            self.log("开始扫描 \(self.config.label) 集合=\(self.sets.map(\.id).joined(separator: ",")) 每组=\(self.packetsPerSet) 总包=\(self.totalPackets) 系统音量=\(String(format: "%.2f", self.outputVolume))")
            self.link.send(WCEnvelope(kind: .started))
            self.log("已发送 started ack")
            await self.run()
        }
    }

    func stop() {
        guard isRunning else { return }
        stopRequested = true
        task?.cancel()
        task = nil
        player.stop()
        isRunning = false
        status = "已停止"
        log("停止扫描；workout 保持")
    }

    /// 扫描完成后保持会话；只有用户主动结束，或手机/手表切到后台才结束。
    func endForeground() {
        if isRunning { stop() }
        workout.end()
        foregroundRunning = false
        foregroundStatus = workout.status
        status = "已结束保持"
        log("结束 workout 保持")
    }

    func noteScenePhase(_ phase: ScenePhase) {
        if phase == .active {
            log("scenePhase active")
            refreshOutputVolume()
            Task { @MainActor in await workout.startIfNeeded(source: "scenePhaseActive") }
        }
    }

    func refreshOutputVolume() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // 读音量失败时保留上一次值；不阻塞 workout/扫描。
        }
        outputVolume = session.outputVolume
    }

    func notifyWatchActive() {
        log("watchActive → phone")
        link.send(WCEnvelope(kind: .watchActive))
    }

    func notifyWatchInactive() {
        log("watchInactive → phone")
        link.send(WCEnvelope(kind: .watchInactive))
    }

    func prepareAudioSession() {
        do {
            try player.preparePlaybackOnly()
        } catch {
            log("音频会话预激活失败 \(error.localizedDescription)")
        }
    }

    deinit {
        volumeTask?.cancel()
    }

    /// 手表上手动开始扫描；手机可以稍后再开始录音。
    func requestStart() {
        guard !isRunning else { return }
        log("手表手动开始；请确认手机已开始录音")
        start()
    }

    func stop(reason: String) {
        guard isRunning else { return }
        log("停止发送 原因=\(reason)")
        stop()
    }

    private func handleEnterBackground() {
        log("applicationDidEnterBackground；结束 workout")
        flushLogs(force: true)
        if isRunning { stop() }
        workout.end()
        foregroundRunning = false
        foregroundStatus = workout.status
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

            status = "扫描完成（保持会话）"
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
        foregroundRunning = workout.running
        foregroundStatus = workout.status
        refreshOutputVolume()
    }

    private func handle(_ envelope: WCEnvelope) {
        switch envelope.kind {
        case .config:
            if let scan = envelope.scanConfig {
                config = scan.normalized
                runLabel = config.label
                status = "已同步：\(config.scenario.title)"
                log("收到手机配置 \(config.label)")
            }
        case .start:
            if let scan = envelope.scanConfig {
                config = scan.normalized
                runLabel = config.label
                log("收到手机开始指令 \(config.label)")
            }
            start()
        case .stop:
            stop(reason: "收到手机停止指令")
        case .endWorkout:
            log("收到手机结束 workout 指令")
            endForeground()
        case .volumeLow, .ready, .watchActive, .watchInactive, .started, .workoutEnded, .finished:
            break
        case .log:
            break
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
    static var onWorkoutConfiguration: ((HKWorkoutConfiguration) -> Void)?
    static var pendingWorkoutConfiguration: HKWorkoutConfiguration?
}
