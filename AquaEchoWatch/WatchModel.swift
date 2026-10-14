import Foundation

@MainActor
final class WatchModel: ObservableObject {
    @Published var config: TestConfig
    @Published var reachable = false
    @Published var isRunning = false
    @Published var status = "等待 iPhone 开始"
    @Published var outputVolume: Float = 0

    private let link = WatchLink()
    private let player = TonePlayer()
    private var stopRequested = false
    private var playing = false

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
        link.activate()
        outputVolume = player.outputVolume
    }

    func requestStart() {
        guard !isRunning else { return }
        link.send(WCEnvelope(kind: .requestStart, config: config, packet: nil, packets: nil, progress: nil))
        status = reachable ? "已请 iPhone 开始录音" : "iPhone 未连接"
    }

    func stop() {
        stopRequested = true
        status = "播完当前包后停止"
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
            stopRequested = true
        case .requestStart, .progress, .packet, .finished:
            break
        }
    }

    private func run() async {
        playing = true
        isRunning = true
        stopRequested = false
        let config = self.config.normalized
        var sent: [SentPacket] = []
        do {
            try player.prepare()
            outputVolume = player.outputVolume
            try await Task.sleep(nanoseconds: 400_000_000)
            var sequence = 0
            let pairs = config.plannedPairs()
            for pair in pairs {
                if stopRequested { break }
                for repeatIndex in 0..<config.repeats {
                    if stopRequested { break }
                    sequence += 1
                    let payload = PacketFactory.randomPayload()
                    let rendered = try render(pair: pair, payload: payload, config: config)
                    status = "\(sequence) · \(pair.label)"
                    link.send(WCEnvelope(
                        kind: .progress,
                        config: nil,
                        packet: nil,
                        packets: nil,
                        progress: "正在发送 \(pair.label)（\(repeatIndex + 1)/\(config.repeats)）"
                    ))
                    let sendDate = try await player.play(samples: rendered.samples, leadSamples: rendered.leadSamples)
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
            status = stopRequested ? "已停止" : "发送完成"
        } catch {
            status = error.localizedDescription
        }
        player.stop()
        link.send(WCEnvelope(kind: .finished, config: config, packet: nil, packets: sent, progress: nil))
        isRunning = false
        playing = false
        outputVolume = player.outputVolume
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
