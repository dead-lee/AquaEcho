import Foundation

/// 把实时解出的包聚合成结果页需要的结构；缺失包补成未检出。
enum ScanResultBuilder {
    static func build(
        config: ScanRunConfig,
        results: [String: ScanPacketResult],
        startedAt: Date,
        finishedAt: Date,
        sampleRate: Double,
        corruptEvents: Int
    ) -> ScanAnalysis {
        let normalized = config.normalized
        let sets = normalized.activeSets
        let packetsPerSet = max(1, min(200, normalized.packetsPerSet))

        var rows: [ScanPacketResult] = []
        for set in sets {
            for index in 0..<packetsPerSet {
                let expected = ScanPayload.make(setID: set.id, packetIndex: index)
                let key = "\(set.id)#\(index)"
                if let hit = results[key] {
                    rows.append(hit)
                } else {
                    rows.append(ScanPacketResult(
                        setID: set.id,
                        setTitle: set.title,
                        carrierCount: set.carrierCount,
                        packetIndex: index,
                        expectedHex: ScanPayload.hex(expected),
                        decodedHex: nil,
                        passed: false,
                        detected: false,
                        snrDB: 0,
                        markerSNRDB: 0,
                        airtimeMs: set.airtimeMs,
                        frameSample: 0,
                        timestamp: nil
                    ))
                }
            }
        }

        var summaries: [ScanSetSummary] = []
        for set in sets {
            let setRows = rows.filter { $0.setID == set.id }
            let detectedRows = setRows.filter { $0.detected }
            let passed = setRows.filter { $0.passed }.count
            summaries.append(ScanSetSummary(
                setID: set.id,
                setTitle: set.title,
                carrierCount: set.carrierCount,
                packets: setRows.count,
                detected: detectedRows.count,
                passed: passed,
                successRate: setRows.isEmpty ? 0 : Double(passed) / Double(setRows.count),
                meanSNRDB: mean(detectedRows.map { $0.snrDB }),
                meanMarkerSNRDB: mean(detectedRows.map { $0.markerSNRDB }),
                airtimeMs: set.airtimeMs,
                corrupt: 0
            ))
        }

        let overallPackets = rows.count
        let overallPassed = rows.filter { $0.passed }.count
        let overallRate = overallPackets == 0 ? 0 : Double(overallPassed) / Double(overallPackets)

        var logs: [String] = []
        logs.append("实时汇总 \(normalized.label) 通过=\(overallPassed)/\(overallPackets) 成功率=\(String(format: "%.1f", overallRate * 100))% 未匹配=\(corruptEvents)")
        for summary in summaries {
            logs.append(String(
                format: "汇总 集合=%@ 通过=%d/%d 成功率=%.1f%% 检出=%d 平均SNR=%.1fdB 标记SNR=%.1fdB airtime=%.1fms",
                locale: Locale(identifier: "en_US_POSIX"),
                summary.setID, summary.passed, summary.packets,
                summary.successRate * 100, summary.detected,
                summary.meanSNRDB, summary.meanMarkerSNRDB, summary.airtimeMs
            ))
        }
        for packet in rows where !packet.detected {
            logs.append("缺失 集合=\(packet.setID) 包=\(packet.packetIndex)")
        }

        return ScanAnalysis(
            config: normalized,
            startedAt: startedAt,
            finishedAt: finishedAt,
            sampleRate: sampleRate,
            packets: rows,
            summaries: summaries,
            overallPackets: overallPackets,
            overallPassed: overallPassed,
            overallRate: overallRate,
            corruptEvents: corruptEvents,
            logLines: logs
        )
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
