import Foundation
import ggwave

/// 对 ggwave C API 的薄封装。超声协议的起始频率在创建实例之前写入全局协议表。
enum GGWaveBridge {
    private static let lock = NSLock()
    private static var didSilenceLog = false

    static func encode(
        payload: Data,
        startHz: Double,
        protocol kind: GGWaveProtocolKind,
        volume: Int
    ) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        silenceLogIfNeeded()
        let bin = Int32(GGWaveBand.bin(forHz: startHz))
        ggwave_txProtocolSetFreqStart(kind.protocolID, bin)
        ggwave_rxProtocolSetFreqStart(kind.protocolID, bin)

        var parameters = ggwave_getDefaultParameters()
        parameters.payloadLength = 0
        parameters.sampleRateInp = Float(GGWaveBand.sampleRate)
        parameters.sampleRateOut = Float(GGWaveBand.sampleRate)
        parameters.sampleRate = Float(GGWaveBand.sampleRate)
        parameters.samplesPerFrame = Int32(GGWaveBand.samplesPerFrame)
        parameters.sampleFormatInp = GGWAVE_SAMPLE_FORMAT_F32
        parameters.sampleFormatOut = GGWAVE_SAMPLE_FORMAT_F32
        parameters.operatingMode = Int32(GGWAVE_OPERATING_MODE_TX)

        let instance = ggwave_init(parameters)
        defer { ggwave_free(instance) }

        let safeVolume = Int32(min(max(volume, 1), 50))
        let byteCount: Int32 = payload.withUnsafeBytes { raw in
            ggwave_encode(instance, raw.baseAddress, Int32(payload.count), kind.protocolID, safeVolume, nil, 1)
        }
        guard byteCount > 0 else { return nil }

        var waveform = [Float](repeating: 0, count: Int(byteCount) / MemoryLayout<Float>.size)
        let written: Int32 = payload.withUnsafeBytes { raw in
            waveform.withUnsafeMutableBytes { destination in
                ggwave_encode(
                    instance,
                    raw.baseAddress,
                    Int32(payload.count),
                    kind.protocolID,
                    safeVolume,
                    destination.baseAddress,
                    0
                )
            }
        }
        let count = max(0, Int(written) / MemoryLayout<Float>.size)
        guard count > 0 else { return nil }
        waveform.removeLast(waveform.count - count)
        normalizeToFullScale(&waveform)
        return waveform
    }

    static func matches(samples: [Float], sampleRate: Double, startHz: Double, protocol kind: GGWaveProtocolKind, payloadHex: String) -> Bool {
        guard let expected = PacketFactory.data(hex: payloadHex), !samples.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        silenceLogIfNeeded()
        let bin = Int32(GGWaveBand.bin(forHz: startHz))
        ggwave_txProtocolSetFreqStart(kind.protocolID, bin)
        ggwave_rxProtocolSetFreqStart(kind.protocolID, bin)

        var parameters = ggwave_getDefaultParameters()
        parameters.payloadLength = 0
        parameters.sampleRateInp = Float(sampleRate)
        parameters.sampleRateOut = Float(GGWaveBand.sampleRate)
        parameters.sampleRate = Float(GGWaveBand.sampleRate)
        parameters.samplesPerFrame = Int32(GGWaveBand.samplesPerFrame)
        parameters.sampleFormatInp = GGWAVE_SAMPLE_FORMAT_F32
        parameters.sampleFormatOut = GGWAVE_SAMPLE_FORMAT_F32
        parameters.operatingMode = Int32(GGWAVE_OPERATING_MODE_RX)

        let instance = ggwave_init(parameters)
        defer { ggwave_free(instance) }

        var decoded = [UInt8](repeating: 0, count: 256)
        let decodedCount: Int32 = samples.withUnsafeBytes { raw in
            decoded.withUnsafeMutableBytes { destination in
                ggwave_ndecode(
                    instance,
                    raw.baseAddress,
                    Int32(raw.count),
                    destination.baseAddress,
                    Int32(destination.count)
                )
            }
        }
        guard decodedCount == Int32(expected.count) else { return false }
        return decoded.prefix(expected.count).elementsEqual(expected)
    }

    /// 音量 50 时多音波形峰值大约只有满幅的一半。归一化到 0.98，把扬声器推到不失真的最大音量。
    private static func normalizeToFullScale(_ samples: inout [Float]) {
        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }
        guard peak > 0.000_1 else { return }
        let gain = 0.98 / peak
        for index in samples.indices {
            samples[index] *= gain
        }
    }

    private static func silenceLogIfNeeded() {
        if !didSilenceLog {
            ggwave_setLogFile(nil)
            didSilenceLog = true
        }
    }
}

private extension GGWaveProtocolKind {
    var protocolID: ggwave_ProtocolId {
        switch self {
        case .ultrasoundNormal: return GGWAVE_PROTOCOL_ULTRASOUND_NORMAL
        case .ultrasoundFast: return GGWAVE_PROTOCOL_ULTRASOUND_FAST
        case .ultrasoundFastest: return GGWAVE_PROTOCOL_ULTRASOUND_FASTEST
        }
    }
}
