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

    private let capture = AudioCapture()
    private let link = PhoneLink()
    private var packets: [SentPacket] = []
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
    }

    func syncConfig() {
        config = config.normalized
        ConfigStore.save(config)
        let delivered = link.send(WCEnvelope(kind: .config, config: config, packet: nil, packets: nil, progress: nil))
        status = delivered ? "配置已传到 Watch。" : "Watch 还没连上。配置已保存，连接后会自动带上。"
        lastError = nil
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
            return
        }
        let allowed = await AudioCapture.requestPermission()
        guard allowed else {
            lastError = "需要麦克风权限才能给信号打分。"
            return
        }
        do {
            try capture.start()
        } catch {
            lastError = error.localizedDescription
            return
        }

        packets = []
        pairs = []
        csvURL = nil
        receivedCount = 0
        expectedCount = plan.count * config.repeats
        didScore = false
        activeConfig = config
        isRunning = true
        runID = UUID()
        UIApplication.shared.isIdleTimerDisabled = true
        status = "正在录音，等待 Watch 播放…"
        let started = link.send(WCEnvelope(kind: .start, config: config, packet: nil, packets: nil, progress: nil))
        if !started {
            capture.stop()
            isRunning = false
            UIApplication.shared.isIdleTimerDisabled = false
            lastError = "Watch 不可达。请先打开手表上的 AquaEcho，并保持 App 在前台。"
            status = "未能开始。"
        }
    }

    func stopTest() {
        guard isRunning else { return }
        _ = link.send(WCEnvelope(kind: .stop, config: nil, packet: nil, packets: nil, progress: nil))
        status = "正在停止，等当前这个包播完…"
        let token = runID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard token == self.runID, self.isRunning else { return }
            await self.scoreAfterTail()
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
                upsert(packet)
                status = "第 \(packet.sequence)/\(max(expectedCount, packet.sequence)) 包 · \(HzFormat.string(packet.lowHz))/\(HzFormat.string(packet.highHz)) Hz"
            }
        case .finished:
            if let packets = envelope.packets, !packets.isEmpty {
                for packet in packets { upsert(packet) }
            }
            if let config = envelope.config {
                activeConfig = config.normalized
            }
            Task { await scoreAfterTail() }
        case .start, .stop:
            break
        }
    }

    private func upsert(_ packet: SentPacket) {
        if let index = packets.firstIndex(where: { $0.sequence == packet.sequence }) {
            packets[index] = packet
        } else {
            packets.append(packet)
        }
        receivedCount = packets.count
    }

    private func scoreAfterTail() async {
        guard isRunning, !didScore else { return }
        didScore = true
        try? await Task.sleep(nanoseconds: 350_000_000)
        let snapshot = capture.snapshot()
        capture.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        let config = activeConfig
        let packets = self.packets
        status = "正在用 Goertzel 评分…"
        let result = await Task.detached(priority: .userInitiated) {
            SignalAnalyzer.analyze(
                capture: snapshot,
                packets: packets,
                config: config,
                mode: config.mode,
                ggwaveMatches: { samples, rate, packet in
                    GGWaveBridge.matches(
                        samples: samples,
                        sampleRate: rate,
                        startHz: packet.lowHz,
                        protocol: config.ggwaveProtocol,
                        payloadHex: packet.payloadHex
                    )
                }
            )
        }.value
        pairs = result.pairs
        isRunning = false
        do {
            csvURL = try CSVExporter.write(pairs: result.pairs, mode: config.mode)
            let best = result.pairs.first
            if let best, best.isRecommended {
                status = "完成。推荐 \(best.label)，总分 \(best.score.total)。"
            } else if let best {
                status = "完成。最高 \(best.score.total) 分（\(best.label)），还没有达到 80 分推荐线。"
            } else {
                status = "完成，但没有收到任何包。"
            }
        } catch {
            lastError = "评分已经算出，CSV 没有写入：\(error.localizedDescription)"
            status = "评分完成。"
        }
    }
}
