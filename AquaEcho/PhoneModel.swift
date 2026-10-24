import Combine
import Foundation
import SwiftUI
import UIKit

/// 录音缓冲。音频回调在非主线程，只做加锁追加；分析在停止后离线进行。
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

    private let capture = AudioCapture()
    private let buffer = PCMBuffer()
    private let link = PhoneLink()
    private var maxTask: Task<Void, Never>?

    init() {
        config = ScanConfigStore.load()
        link.onEnvelope = { [weak self] envelope in
            Task { @MainActor in self?.handle(envelope) }
        }
        link.onReachable = { [weak self] value in
            Task { @MainActor in self?.reachable = value }
        }
        link.onActivated = { [weak self] value in
            Task { @MainActor in self?.activated = value }
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
        guard !isRecording, !isAnalyzing else { return }
        lastError = nil
        analysis = nil
        csvURL = nil
        wavURL = nil
        scanLogURL = nil
        config = config.normalized
        ScanConfigStore.save(config)

        let allowed = await AudioCapture.requestPermission()
        guard allowed else {
            lastError = "没有麦克风权限，无法录音。请到系统设置里给 AquaEcho 打开麦克风。"
            log("错误 \(lastError ?? "")")
            return
        }

        buffer.reset()
        let buffer = self.buffer
        capture.onSamples = { chunk, _, rate in
            buffer.append(chunk, rate: rate)
        }
        do {
            try capture.start()
        } catch {
            capture.onSamples = nil
            lastError = error.localizedDescription
            log("错误 \(error.localizedDescription)")
            return
        }

        isRecording = true
        startedAt = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        log("开始录音 \(config.label) 集合=\(config.activeSets.map(\.id).joined(separator: ",")) 预计包=\(expectedPackets) 预计=\(String(format: "%.1f", expectedSeconds))s 构建=\(AppBuild.number)")

        let sent = link.send(WCEnvelope(kind: .start, scanConfig: config))
        status = sent
            ? "录音中。手机已请求手表开始扫描；把两台设备放到测试位置。"
            : "录音中。手表不可达，请在手表的 AquaEcho 上手动点开始扫描。"
        log(sent ? "已请求手表开始扫描（手表日志会记录收到）" : "手表不可达：请在手表的 AquaEcho 上手动点开始扫描")

        maxTask?.cancel()
        maxTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            guard let self, self.isRecording else { return }
            self.log("达到最长录音时间，自动停止并分析")
            self.stopAndAnalyze()
        }
    }

    func stopAndAnalyze() {
        guard isRecording else { return }
        isRecording = false
        isAnalyzing = true
        status = "正在保存录音并分析…"
        maxTask?.cancel()
        maxTask = nil
        capture.onSamples = nil
        capture.stop()
        UIApplication.shared.isIdleTimerDisabled = false

        let (samples, rate) = buffer.snapshot()
        let started = startedAt ?? Date()
        let config = self.config
        guard !samples.isEmpty else {
            isAnalyzing = false
            lastError = "没有录到样本。"
            status = "没有录音数据"
            log("错误 没有录到样本")
            return
        }

        log("停止录音 样本=\(samples.count) 采样率=\(Int(rate.rounded())) 场景=\(config.scenario.title)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 先落盘 WAV：即使后续分析失败，原始录音也一定保留。
            let wav = try? SessionRecording.write(
                samples: samples,
                sampleRate: rate,
                prefix: "AquaEcho_Scan_\(config.scenario.fileTag)_"
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.wavURL = wav
                if let wav {
                    self.log("录音已写入 \(wav.lastPathComponent)（\(samples.count) 样本）")
                } else {
                    self.log("错误 WAV 写入失败")
                }
            }

            let analysis = ScanAnalyzer.analyze(
                samples: samples,
                sampleRate: rate,
                config: config,
                startedAt: started
            )
            let csv = try? ScanCSVExporter.write(analysis)
            let scanLog = try? ScanCSVExporter.writeLog(analysis)

            DispatchQueue.main.async {
                guard let self else { return }
                self.analysis = analysis
                self.wavURL = wav
                self.csvURL = csv
                self.scanLogURL = scanLog
                self.isAnalyzing = false
                self.status = "完成：\(analysis.overallPassed)/\(analysis.overallPackets) 通过（\(String(format: "%.1f", analysis.overallRate * 100))%）"
                for line in analysis.logLines {
                    RunLog.shared.append("[Scan] \(line)")
                }
                self.log("分析完成 \(config.label) 通过=\(analysis.overallPassed)/\(analysis.overallPackets) 成功率=\(String(format: "%.1f", analysis.overallRate * 100))% WAV=\(wav?.lastPathComponent ?? "无") CSV=\(csv?.lastPathComponent ?? "无")")
            }
        }
    }

    func noteScenePhase(_ phase: ScenePhase) {
        guard phase == .background, isRecording else { return }
        log("App 进入后台，录音可能被系统中断，自动停止并分析")
        stopAndAnalyze()
    }

    func reloadLog() {
        logText = RunLog.shared.text()
    }

    func clearResultFiles() {
        let urls = RunLog.documentFiles(prefixes: ["AquaEcho_Scan_", "AquaEcho_ScanLog_"])
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        RunLog.shared.discardBufferedLines()
        logText = ""
        analysis = nil
        csvURL = nil
        wavURL = nil
        scanLogURL = nil
        status = "已清理扫描 CSV/WAV/日志"
    }

    private func handle(_ envelope: WCEnvelope) {
        switch envelope.kind {
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
        case .config, .start, .stop:
            break
        }
    }

    private func log(_ message: String) {
        RunLog.shared.append("[Phone][Scan] \(message)")
    }
}
