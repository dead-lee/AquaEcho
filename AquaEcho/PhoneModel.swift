import Combine
import Foundation
import HealthKit
import SwiftUI
import UIKit

/// 录音缓冲。音频回调在非主线程，只做加锁追加；实时解码由 ScanReceiver 负责。
final class PCMBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: false)
        sampleRate = 48_000
        lock.unlock()
    }

    func append(_ chunk: [Float], rate: Double) {
        lock.lock()
        sampleRate = rate
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func snapshot() -> ([Float], Double) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, sampleRate)
    }
}

@MainActor
final class PhoneModel: ObservableObject {
    @Published var config: ScanRunConfig
    @Published private(set) var isRecording = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var status = "选择场景，点“开始测试”；手机会同时启动手表。"
    @Published private(set) var startedAt: Date?
    @Published private(set) var analysis: ScanAnalysis?
    @Published private(set) var csvURL: URL?
    @Published private(set) var wavURL: URL?
    @Published private(set) var scanLogURL: URL?
    @Published private(set) var logText = ""
    @Published private(set) var lastError: String?
    @Published private(set) var reachable = false
    @Published private(set) var activated = false
    @Published private(set) var watchReady = false
    @Published private(set) var watchSessionStatus = "未启动"

    private let capture = AudioCapture()
    private let buffer = PCMBuffer()
    private let link = PhoneLink()
    private let healthStore = HKHealthStore()
    private let demodQueue = DispatchQueue(label: "aquaecho.scan.receiver")
    private var watchLaunchRequested = false
    private var watchLaunchInFlight = false
    private var pendingStart = false
    private var isStarting = false
    private let mainWatchdog = MainThreadWatchdog()
    private var receiver: ScanReceiver?
    private var maxTask: Task<Void, Never>?

    init() {
        config = ScanConfigStore.load()
        link.onEnvelope = { [weak self] envelope in
            Task { @MainActor in self?.handle(envelope) }
        }
        link.onReachable = { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                let old = self.reachable
                self.reachable = value
                self.log("WCSession reachable \(old) → \(value)（activated=\(self.activated), watchReady=\(self.watchReady), pendingStart=\(self.pendingStart), recording=\(self.isRecording)）")
                if value && self.isRecording && self.pendingStart {
                    self.sendStart(reason: "reachable")
                }
            }
        }
        link.onActivated = { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                self.activated = value
                self.log("WCSession activated=\(value)（reachable=\(self.reachable), watchReady=\(self.watchReady), pendingStart=\(self.pendingStart), recording=\(self.isRecording)）")
                if value && self.isRecording && self.pendingStart {
                    self.sendStart(reason: "activated")
                }
            }
        }
        link.activate()
        RunLog.shared.onAppend = { [weak self] line in
            self?.logText += line
        }
        log("应用启动 构建 \(AppBuild.number) 日志 \(RunLog.shared.fileURL.lastPathComponent)")
    }

    var expectedPackets: Int {
        config.activeSets.count * max(1, config.packetsPerSet)
    }

    var expectedSeconds: Double {
        ScanProtocol.expectedSeconds(for: config)
    }

    var logURL: URL { RunLog.shared.fileURL }

    var isRunning: Bool { isRecording }

    func syncConfig() {
        config = config.normalized
        ScanConfigStore.save(config)
        let sent = link.send(WCEnvelope(kind: .config, scanConfig: config))
        status = sent ? "配置已发送到手表。" : "手表不可达，配置只保存在手机。"
        log(status)
    }

    /// 手机 App 启动就唤起手表并建立 workout 会话，降低开始测试时手表没醒来的概率。
    func prepareWatchOnLaunch() async {
        guard !watchLaunchInFlight else { return }
        if watchReady { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            watchSessionStatus = "HealthKit 不可用"
            log("错误 HealthKit 不可用")
            return
        }
        watchLaunchInFlight = true
        watchLaunchRequested = true
        defer { watchLaunchInFlight = false }

        do {
            try await requestHealthAuthorization()
            syncConfig()
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .other
            configuration.locationType = .outdoor
            try await startWatchApp(configuration)
            watchSessionStatus = "手表唤起中"
            status = "已请求唤起手表并启动 workout 会话。"
            log("已调用 startWatchApp，等待手表 ready")
        } catch {
            watchLaunchRequested = false
            watchSessionStatus = "启动失败"
            lastError = error.localizedDescription
            status = "手表会话启动失败：\(error.localizedDescription)"
            log("错误 startWatchApp/\(error.localizedDescription)")
        }
    }

    private func requestHealthAuthorization() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let share: Set<HKSampleType> = [HKObjectType.workoutType()]
            let read: Set<HKObjectType> = [HKObjectType.workoutType()]
            healthStore.requestAuthorization(toShare: share, read: read) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(domain: "AquaEcho.HealthKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "HealthKit 授权被拒绝"]))
                }
            }
        }
    }

    private func startWatchApp(_ configuration: HKWorkoutConfiguration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.startWatchApp(with: configuration) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(domain: "AquaEcho.HealthKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "手表 App 未能启动"]))
                }
            }
        }
    }

    func startTest() async {
        await startRecording()
    }

    func stopTest() {
        if isRecording {
            _ = link.send(WCEnvelope(kind: .stop))
            log("已请求手表停止")
        }
        stopAndAnalyze()
    }

    func startRecording() async {
        guard !isRecording, !isAnalyzing, !isStarting else {
            log("忽略重复开始：recording=\(isRecording), analyzing=\(isAnalyzing), starting=\(isStarting)")
            return
        }
        isStarting = true
        defer { isStarting = false }
        RunLog.shared.resumeNewLogIfSuspended()
        lastError = nil
        analysis = nil
        csvURL = nil
        wavURL = nil
        scanLogURL = nil
        config = config.normalized
        ScanConfigStore.save(config)

        log("准备开始：watchReady=\(watchReady), activated=\(activated), reachable=\(reachable)")
        if !watchReady {
            await prepareWatchOnLaunch()
            for _ in 0..<20 {
                if watchReady { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        log("准备结束：watchReady=\(watchReady), activated=\(activated), reachable=\(reachable)")

        let allowed = await AudioCapture.requestPermission()
        guard allowed else {
            lastError = "没有麦克风权限，无法录音。请到系统设置里给 AquaEcho 打开麦克风。"
            log("错误 \(lastError ?? "")")
            return
        }

        buffer.reset()
        let started = Date()
        let receiver = ScanReceiver(config: config, startedAt: started)
        receiver.onUpdate = { [weak self] analysis in
            Task { @MainActor in self?.applyLive(analysis) }
        }
        receiver.onLog = { line in
            RunLog.shared.append("[Scan] \(line)")
        }
        self.receiver = receiver
        let buffer = self.buffer
        let demodQueue = self.demodQueue
        capture.onSamples = { chunk, date, rate in
            buffer.append(chunk, rate: rate)
            demodQueue.async {
                receiver.ingest(chunk, at: date, sampleRate: rate)
            }
        }
        do {
            try capture.start()
        } catch {
            capture.onSamples = nil
            self.receiver = nil
            lastError = error.localizedDescription
            log("错误 \(error.localizedDescription)")
            return
        }

        isRecording = true
        startedAt = started
        UIApplication.shared.isIdleTimerDisabled = true
        log("开始录音 \(config.label) 集合=\(config.activeSets.map(\.id).joined(separator: ",")) 预计包=\(expectedPackets) 预计=\(String(format: "%.1f", expectedSeconds))s 构建=\(AppBuild.number)")

        _ = sendStart(reason: "userStart")

        maxTask?.cancel()
        maxTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            guard let self, self.isRecording else { return }
            self.log("达到最长录音时间，自动停止")
            self.stopAndAnalyze()
        }
    }

    func stopAndAnalyze() {
        guard isRecording else { return }
        isRecording = false
        isAnalyzing = true
        pendingStart = false
        status = "正在保存录音…"
        maxTask?.cancel()
        maxTask = nil
        capture.onSamples = nil
        capture.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        log("停止开始：capture.stop 完成，准备后台快照/接收器 finish")

        let receiver = self.receiver
        self.receiver = nil
        let buffer = self.buffer
        let started = startedAt ?? Date()
        let config = self.config
        demodQueue.async { [weak self] in
            let begin = Date()
            RunLog.shared.append("[Phone][Scan] 后台停止阶段开始：buffer.snapshot")
            let (samples, rate) = buffer.snapshot()
            RunLog.shared.append("[Phone][Scan] buffer.snapshot 完成 samples=\(samples.count) rate=\(Int(rate.rounded()))")
            RunLog.shared.append("[Phone][Scan] receiver.finish 开始")
            let final = receiver?.finish()
            let elapsed = Date().timeIntervalSince(begin)
            RunLog.shared.append("[Phone][Scan] receiver.finish 完成 用时=\(String(format: "%.3f", elapsed))s")
            DispatchQueue.main.async {
                self?.finishAnalysis(final: final, samples: samples, rate: rate, started: started, config: config)
            }
        }
    }

    private func finishAnalysis(final: ScanAnalysis?, samples: [Float], rate: Double, started: Date, config: ScanRunConfig) {
        guard !samples.isEmpty else {
            isAnalyzing = false
            lastError = "没有录到样本。"
            status = "没有录音数据"
            log("错误 没有录到样本")
            return
        }

        log("停止录音 样本=\(samples.count) 采样率=\(Int(rate.rounded())) 场景=\(config.scenario.title)")
        let analysis = final ?? ScanResultBuilder.build(
            config: config,
            results: [:],
            startedAt: started,
            finishedAt: Date(),
            sampleRate: rate,
            corruptEvents: 0
        )
        self.analysis = analysis
        self.status = "完成：\(analysis.overallPassed)/\(analysis.overallPackets) 通过（\(String(format: "%.1f", analysis.overallRate * 100))%）"
        for line in analysis.logLines {
            RunLog.shared.append("[Scan] \(line)")
        }
        log("实时解码结束 通过=\(analysis.overallPassed)/\(analysis.overallPackets) 成功率=\(String(format: "%.1f", analysis.overallRate * 100))%")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            RunLog.shared.append("[Phone][Scan] 写盘开始：WAV/CSV/ScanLog")
            let wav = try? SessionRecording.write(
                samples: samples,
                sampleRate: rate,
                prefix: "AquaEcho_Scan_\(config.scenario.fileTag)_"
            )
            let csv = try? ScanCSVExporter.write(analysis)
            let scanLog = try? ScanCSVExporter.writeLog(analysis)
            DispatchQueue.main.async {
                guard let self else { return }
                self.wavURL = wav
                self.csvURL = csv
                self.scanLogURL = scanLog
                self.isAnalyzing = false
                if let wav {
                    self.log("录音已写入 \(wav.lastPathComponent)（\(samples.count) 样本）")
                }
                self.log("结果已写入 CSV=\(csv?.lastPathComponent ?? "无") 日志=\(scanLog?.lastPathComponent ?? "无")")
            }
        }
    }

    @discardableResult
    private func sendStart(reason: String) -> Bool {
        let sent = link.send(WCEnvelope(kind: .start, scanConfig: config))
        let state = "watchReady=\(watchReady), activated=\(activated), reachable=\(reachable), recording=\(isRecording)"
        log("发送 start reason=\(reason) 结果=\(sent ? "成功" : "失败")（\(state)）")
        if sent {
            pendingStart = false
            status = watchReady
                ? "录音中。手表已就绪，开始指令已发送。"
                : "录音中。开始指令已发送，等待手表就绪。"
        } else {
            pendingStart = true
            status = "录音中。手表连接未就绪，已排队；ready/连接恢复后自动补发开始。"
            log("start 未发出：已进入 pendingStart，等待 ready/activated/reachable 后自动重发")
        }
        return sent
    }

    private func abortRecording(reason: String) {
        guard isRecording else {
            status = reason
            return
        }
        isRecording = false
        isAnalyzing = false
        pendingStart = false
        maxTask?.cancel()
        maxTask = nil
        capture.onSamples = nil
        capture.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        let oldReceiver = receiver
        receiver = nil
        demodQueue.async {
            _ = oldReceiver?.finish()
        }
        lastError = reason
        status = reason
        log("中止录音：\(reason)")
    }

    private func applyLive(_ analysis: ScanAnalysis) {
        guard isRecording else { return }
        self.analysis = analysis
        status = "录音中：已解 \(analysis.overallPassed)/\(analysis.overallPackets)（\(String(format: "%.1f", analysis.overallRate * 100))%）"
    }

    func noteScenePhase(_ phase: ScenePhase) {
        guard phase == .background else { return }
        log("手机 App 进入后台；按要求结束手表 workout 保持")
        if watchReady || watchLaunchRequested {
            _ = link.send(WCEnvelope(kind: .endWorkout))
        }
        watchReady = false
        watchLaunchRequested = false
        pendingStart = false
        watchSessionStatus = "已结束"
        if isRecording {
            stopAndAnalyze()
        }
    }

    func reloadLog() {
        logText = RunLog.shared.text()
    }

    func clearResultFiles() {
        guard !isRecording else {
            status = "录音中不能清理，请先停止。"
            return
        }
        let urls = RunLog.documentFiles(prefixes: ["AquaEcho_Scan_", "AquaEcho_ScanLog_"])
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        RunLog.shared.purgeAll()
        logText = ""
        analysis = nil
        csvURL = nil
        wavURL = nil
        scanLogURL = nil
        status = "已完全清理扫描文件与所有日志"
    }

    private func handle(_ envelope: WCEnvelope) {
        switch envelope.kind {
        case .ready:
            watchReady = true
            watchSessionStatus = "保持中"
            log("收到 ready（recording=\(isRecording), pendingStart=\(pendingStart), activated=\(activated), reachable=\(reachable)）")
            if isRecording {
                if pendingStart {
                    _ = sendStart(reason: "ready")
                }
            } else {
                status = "手表 workout 已就绪，可以开始测试。"
            }
        case .workoutEnded:
            watchReady = false
            pendingStart = false
            watchSessionStatus = "已结束"
            log("手表 workout 已结束")
            if !isRecording {
                status = "手表 workout 已结束；下次开始测试会重新唤起。"
            }
        case .volumeLow:
            abortRecording(reason: "手表系统音量未到 100%，已停止。请调大后重试。")
        case .finished:
            if isRecording {
                log("收到手表扫描完成消息，自动停止并分析")
                stopAndAnalyze()
            }
        case .log:
            if let line = envelope.log {
                for part in line.split(separator: "\n", omittingEmptySubsequences: true) {
                    RunLog.shared.append(String(part))
                }
            }
        case .config, .start, .stop, .endWorkout:
            break
        }
    }

    private func log(_ message: String) {
        RunLog.shared.append("[Phone][Scan] \(message)")
    }
}

/// 只在后台队列计时，主线程阻塞时仍能写日志；不能反过来阻塞主线程。
private final class MainThreadWatchdog {
    private let queue = DispatchQueue(label: "AquaEcho.MainThreadWatchdog")
    private let lock = NSLock()
    private var lastBeat = Date()
    private var reported = false
    private var timer: DispatchSourceTimer?

    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let elapsed = Date().timeIntervalSince(self.lastBeat)
            let alreadyReported = self.reported
            self.lock.unlock()

            if elapsed > 2 {
                if !alreadyReported {
                    self.lock.lock()
                    self.reported = true
                    self.lock.unlock()
                    RunLog.shared.append("[Phone][Main] 主线程超过 \(String(format: "%.1f", elapsed)) 秒未响应")
                }
            } else if elapsed < 0.5 {
                self.lock.lock()
                self.reported = false
                self.lock.unlock()
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.lastBeat = Date()
                self.lock.unlock()
            }
        }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
    }
}
