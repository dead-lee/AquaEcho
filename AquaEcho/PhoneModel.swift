import Foundation
import UIKit

@MainActor
final class PhoneModel: ObservableObject {
    @Published var config: TestConfig
    @Published var reachable = false
    @Published var activated = false
    @Published var isRunning = false
    @Published var status = "把 Watch 音量调到最大，再开始测试。"
    @Published var pairs: [PairScore] = []
    @Published var csvURL: URL?
    @Published var lastError: String?
    @Published var receivedCount = 0
    @Published var expectedCount = 0
    @Published var logText = ""
    @Published var logURL: URL?
    @Published var cleanupMessage: String?

    private let capture = AudioCapture()
    private let link = PhoneLink()
    private let demodQueue = DispatchQueue(label: "aquaecho.demod")
    private let recordingLock = NSLock()
    private var recordingSamples: [Float] = []
    private var recordingRate = 48_000.0
    private var receiver: SignalAnalyzer.Receiver?
    private var activeConfig = TestConfig()
    private var didScore = false
    private var runID = UUID()

    init() {
        config = ConfigStore.load()
        link.onEnvelope = { [weak self] envelope in
            Task { @MainActor in
                self?.handle(envelope)
            }
        }
        link.onReachable = { [weak self] value in
            Task { @MainActor in
                self?.reachable = value
            }
        }
        link.onActivated = { [weak self] value in
            Task { @MainActor in
                self?.activated = value
            }
        }
        link.activate()
        logURL = RunLog.shared.fileURL
        RunLog.shared.onAppend = { [weak self] _ in
            self?.logText = RunLog.shared.text()
        }
        log("应用启动。构建 \(AppBuild.number)。日志 \(RunLog.shared.fileURL.lastPathComponent)")
    }

    func reloadLog() {
        logText = RunLog.shared.text()
        logURL = RunLog.shared.fileURL
    }

    func syncConfig() {
        config = config.normalized
        ConfigStore.save(config)
        let delivered = link.send(WCEnvelope(kind: .config, config: config, packet: nil, packets: nil, progress: nil))
        status = delivered ? "配置已传到 Watch。" : "Watch 还没连上。配置已保存，连接后会自动带上。"
        lastError = nil
        log(status)
    }

    func startTest() async {
        guard !isRunning else { return }
        lastError = nil
        let config = config.normalized
        self.config = config
        ConfigStore.save(config)
        let plan = config.plannedPairs()
        guard !plan.isEmpty else {
            lastError = "这个频率范围放不下一组测试。请提高上限，或减小步进。"
            log("错误 \(lastError ?? "")")
            return
        }
        let allowed = await AudioCapture.requestPermission()
        guard allowed else {
            lastError = "需要麦克风权限才能给信号打分。"
            log("错误 \(lastError ?? "")")
            return
        }
        do {
            try capture.start()
        } catch {
            lastError = error.localizedDescription
            log("错误 \(error.localizedDescription)")
            return
        }

        pairs = []
        csvURL = nil
        receivedCount = 0
        expectedCount = plan.count * config.repeats
        didScore = false
        activeConfig = config
        var schedule: [PlannedPair] = []
        for pair in plan {
            for _ in 0..<config.repeats {
                schedule.append(pair)
            }
        }
        let live = SignalAnalyzer.Receiver(config: config, schedule: schedule)
        live.onUpdate = { [weak self] update in
            DispatchQueue.main.async {
                self?.show(update)
            }
        }
        live.onLog = { [weak self] line in
            DispatchQueue.main.async {
                self?.log(line)
            }
        }
        receiver = live
        recordingLock.lock()
        recordingSamples.removeAll(keepingCapacity: false)
        recordingRate = config.sampleRate
        recordingLock.unlock()
        capture.onSamples = { [weak self] samples, date, rate in
            guard let self else { return }
            self.keepRecording(samples, sampleRate: rate)
            self.demodQueue.async {
                live.ingest(samples, at: date, sampleRate: rate)
            }
        }
        isRunning = true
        runID = UUID()
        UIApplication.shared.isIdleTimerDisabled = true
        status = "正在录音，等待 Watch 播放…"
        log("开始录音，等待 \(expectedCount) 个包")
        let started = link.send(WCEnvelope(kind: .start, config: config, packet: nil, packets: nil, progress: nil))
        if !started {
            capture.onSamples = nil
            capture.stop()
            demodQueue.sync {}
            isRunning = false
            UIApplication.shared.isIdleTimerDisabled = false
            lastError = "Watch 不可达。请先打开手表上的 AquaEcho，并保持 App 在前台。"
            status = "未能开始。"
            log("错误 \(lastError ?? "")")
        }
    }

    func stopTest() {
        guard isRunning else { return }
        _ = link.send(WCEnvelope(kind: .stop, config: nil, packet: nil, packets: nil, progress: nil))
        status = "正在停止，等当前这个包播完…"
        log("请求停止发送")
        let token = runID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard token == self.runID, self.isRunning else { return }
            self.beginFinish()
        }
    }

    private func handle(_ envelope: WCEnvelope) {
        switch envelope.kind {
        case .config:
            if let config = envelope.config {
                self.config = config.normalized
                ConfigStore.save(self.config)
            }
        case .requestStart:
            Task { await startTest() }
        case .progress:
            if let progress = envelope.progress, isRunning {
                status = progress
            }
        case .packet:
            if let packet = envelope.packet {
                receiver?.note(packet)
                log("收到包 \(packet.sequence) \(HzFormat.string(packet.lowHz))/\(HzFormat.string(packet.highHz)) Hz 发送时间 \(RunLog.timestamp(packet.watchSendDate))")
            }
        case .log:
            if let line = envelope.log {
                for part in line.split(separator: "\n", omittingEmptySubsequences: true) {
                    RunLog.shared.append(String(part))
                }
            }
        case .finished:
            if let packets = envelope.packets, !packets.isEmpty {
                for packet in packets {
                    receiver?.note(packet)
                }
            }
            if let config = envelope.config {
                activeConfig = config.normalized
            }
            beginFinish()
        case .start, .stop:
            break
        }
    }

    private func show(_ update: SignalAnalyzer.Receiver.Update) {
        guard !didScore else { return }
        receivedCount = update.processedCount
        let packet = update.transmission.packet
        let verdict = update.transmission.passed ? "通过" : "未通过"
        status = "第 \(packet.sequence)/\(max(expectedCount, packet.sequence)) 包 · \(HzFormat.string(packet.lowHz))/\(HzFormat.string(packet.highHz)) Hz · \(verdict)"
    }

    private func beginFinish() {
        guard isRunning, !didScore else { return }
        didScore = true
        status = "测试完成"
        isRunning = false
        capture.onSamples = nil
        capture.stop()
        demodQueue.sync {}
        UIApplication.shared.isIdleTimerDisabled = false
        writeRecording()
        let scored = receiver?.finish() ?? []
        receiver = nil
        pairs = scored
        receivedCount = scored.reduce(0) { $0 + $1.transmissions.count }
        do {
            csvURL = try CSVExporter.write(pairs: scored, mode: activeConfig.mode)
            log("CSV 已写入 \(csvURL?.lastPathComponent ?? "")")
            status = "测试完成"
        } catch {
            lastError = "评分已经算出，CSV 没有写入：\(error.localizedDescription)"
            status = "测试完成"
            log("错误 \(lastError ?? "")")
        }
    }

    func clearResultFiles() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in urls {
            let name = url.lastPathComponent
            let csv = name.hasPrefix("AquaEcho_Results_") && name.hasSuffix(".csv")
            let logFile = name.hasPrefix("AquaEcho_Log_") && name.hasSuffix(".txt")
            let recording = name.hasPrefix("AquaEcho_Recording_") && name.hasSuffix(".wav")
            if csv || logFile || recording {
                try? FileManager.default.removeItem(at: url)
            }
        }
        csvURL = nil
        RunLog.shared.discardBufferedLines()
        logText = ""
        cleanupMessage = "已清理 CSV、日志和调试录音"
    }

    private func keepRecording(_ samples: [Float], sampleRate: Double) {
        recordingLock.lock()
        recordingRate = sampleRate
        recordingSamples.append(contentsOf: samples)
        recordingLock.unlock()
    }

    private func writeRecording() {
        recordingLock.lock()
        let samples = recordingSamples
        let rate = recordingRate
        recordingSamples.removeAll(keepingCapacity: false)
        recordingLock.unlock()
        guard !samples.isEmpty else { return }
        do {
            let url = try SessionRecording.write(samples: samples, sampleRate: rate)
            log("调试录音已写入 \(url.lastPathComponent) 采样=\(samples.count) 采样率=\(Int(rate.rounded()))")
        } catch {
            log("错误 调试录音没有写入：\(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        RunLog.shared.append("[iPhone] \(message)")
    }
}
