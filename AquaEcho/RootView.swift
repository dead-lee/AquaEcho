import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            TestScreen()
                .tabItem { Label("测试", systemImage: "waveform") }
            ResultsScreen()
                .tabItem { Label("结果", systemImage: "chart.bar") }
            ConfigScreen()
                .tabItem { Label("配置", systemImage: "slider.horizontal.3") }
            LogScreen()
                .tabItem { Label("日志", systemImage: "doc.text") }
        }
        .onChange(of: scenePhase) { _, phase in
            model.noteScenePhase(phase)
        }
    }
}

// MARK: - 测试

private struct TestScreen: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationStack {
            List {
                Section("当前场景") {
                    Text(model.config.scenario.title)
                        .font(.title2.bold())
                    Picker("场景", selection: $model.config.scenario) {
                        ForEach(TestScenario.allCases) { scenario in
                            Text(scenario.title).tag(scenario)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(model.config.scenario.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("测试条件") {
                    HStack {
                        Text("距离")
                        TextField("cm", value: $model.config.distanceCm, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("cm").foregroundStyle(.secondary)
                    }
                    TextField("备注（袋型 / 深度 / 朝向）", text: $model.config.notes, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section("本次") {
                    Picker("每组包数", selection: $model.config.packetsPerSet) {
                        Text("20（快筛）").tag(20)
                        Text("50（精确）").tag(50)
                        Text("100").tag(100)
                    }
                    LabeledContent("预计包数", value: "\(model.expectedPackets)")
                    LabeledContent("预计时长", value: String(format: "%.1f 秒", model.expectedSeconds))
                    LabeledContent("手表", value: model.reachable ? "已连接" : (model.activated ? "未打开" : "会话未激活"))
                    if let analysis = model.analysis {
                        LabeledContent("上次通过", value: "\(analysis.overallPassed)/\(analysis.overallPackets)")
                    }
                }

                Section("状态") {
                    Text(model.status)
                        .font(.footnote)
                    if let started = model.startedAt, model.isRecording {
                        TimelineView(.periodic(from: .now, by: 0.5)) { context in
                            LabeledContent("已录", value: String(format: "%.1f 秒", context.date.timeIntervalSince(started)))
                        }
                    }
                    if model.isAnalyzing {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("正在保存并分析…").font(.caption)
                        }
                    }
                    if let error = model.lastError {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("AquaEcho")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if model.isRecording {
                        Button("停止并评分", role: .destructive) {
                            model.stopTest()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Button("开始测试") {
                            Task { await model.startTest() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.isAnalyzing)
                    }
                    Text("手机会请求手表同时开始扫描；停止后先保存 WAV，再离线分析。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
    }
}

// MARK: - 结果

private struct ResultsScreen: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationStack {
            Group {
                if let analysis = model.analysis {
                    List {
                        Section("场景") {
                            LabeledContent("场景", value: analysis.config.scenario.title)
                            LabeledContent("距离", value: String(format: "%.1f cm", analysis.config.distanceCm))
                            LabeledContent("备注", value: analysis.config.notes.isEmpty ? "无" : analysis.config.notes)
                            LabeledContent("每组包数", value: "\(analysis.config.packetsPerSet)")
                            LabeledContent("开始", value: RunLog.timestamp(analysis.startedAt))
                            LabeledContent("结束", value: RunLog.timestamp(analysis.finishedAt))
                            LabeledContent("构建", value: AppBuild.number)
                        }
                        Section("总体") {
                            HStack {
                                Text("\(analysis.overallPassed)/\(analysis.overallPackets)")
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                Text(String(format: "%.1f%%", analysis.overallRate * 100))
                                    .font(.title2.bold())
                                    .foregroundStyle(analysis.overallRate >= 0.8 ? .green : .orange)
                                Spacer()
                            }
                            Text("80% 目标 \(analysis.overallRate >= 0.8 ? "已达到" : "未达到")；伪包 \(analysis.corruptEvents) 个。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Section("按集合") {
                            ForEach(analysis.summaries) { summary in
                                ScanSetRow(summary: summary)
                            }
                        }
                        Section("文件") {
                            if let url = model.csvURL {
                                ShareLink(item: url) { Label("导出 CSV", systemImage: "square.and.arrow.up") }
                            }
                            if let url = model.wavURL {
                                ShareLink(item: url) { Label("导出 WAV", systemImage: "waveform") }
                            }
                            if let url = model.scanLogURL {
                                ShareLink(item: url) { Label("导出分析日志", systemImage: "doc.text") }
                            }
                        }
                        Section("明细") {
                            NavigationLink("查看每包结果") {
                                ScanPacketDetailView(analysis: analysis)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "还没有结果",
                        systemImage: "chart.bar",
                        description: Text("在“测试”页开始，手机会同时启动手表；停止或收到手表完成消息后自动分析。")
                    )
                }
            }
            .navigationTitle("结果")
        }
    }
}

private struct ScanSetRow: View {
    let summary: ScanSetSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(summary.setTitle).font(.subheadline.bold())
                Spacer()
                Text("\(summary.passed)/\(summary.packets)")
                    .font(.subheadline.monospacedDigit())
                Text(String(format: "%.0f%%", summary.successRate * 100))
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(summary.successRate >= 0.8 ? .green : .orange)
            }
            ProgressView(value: summary.successRate)
                .tint(summary.successRate >= 0.8 ? .green : .orange)
            HStack {
                Text("\(summary.carrierCount) 子载波")
                Text("· \(String(format: "%.0f", summary.airtimeMs)) ms/包")
                Text("· SNR \(String(format: "%.1f", summary.meanSNRDB)) dB")
                if summary.corrupt > 0 {
                    Text("· 伪包 \(summary.corrupt)").foregroundStyle(.red)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ScanPacketDetailView: View {
    let analysis: ScanAnalysis

    var body: some View {
        List {
            ForEach(analysis.summaries) { summary in
                Section(summary.setTitle) {
                    ForEach(analysis.packets.filter { $0.setID == summary.setID }) { packet in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: statusIcon(packet))
                                    .foregroundStyle(statusColor(packet))
                                Text("包 \(packet.packetIndex)").font(.subheadline.bold())
                                Spacer()
                                Text(statusText(packet))
                                    .font(.caption)
                                    .foregroundStyle(statusColor(packet))
                            }
                            Text("期望 \(packet.expectedHex)").font(.caption2.monospaced())
                            Text(decodedLabel(packet))
                                .font(.caption2.monospaced())
                                .foregroundStyle(packet.passed ? .gray : .red)
                            Text(metricsLabel(packet))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("每包结果")
    }

    private func decodedLabel(_ packet: ScanPacketResult) -> String {
        "解出 " + (packet.decodedHex ?? "—")
    }

    private func statusIcon(_ packet: ScanPacketResult) -> String {
        if packet.passed { return "checkmark.circle.fill" }
        if packet.detected { return "xmark.circle.fill" }
        return "circle.dashed"
    }

    private func statusColor(_ packet: ScanPacketResult) -> Color {
        if packet.passed { return .green }
        if packet.detected { return .red }
        return .gray
    }

    private func statusText(_ packet: ScanPacketResult) -> String {
        if packet.passed { return "通过" }
        if packet.detected { return "失败" }
        return "缺失"
    }

    private func metricsLabel(_ packet: ScanPacketResult) -> String {
        let snr = String(format: "%.1f", packet.snrDB)
        let marker = String(format: "%.1f", packet.markerSNRDB)
        let air = String(format: "%.0f", packet.airtimeMs)
        return "SNR \(snr) dB · 标记 \(marker) dB · \(air) ms"
    }
}

// MARK: - 配置

private struct ConfigScreen: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationStack {
            List {
                Section("扫描集合") {
                    ForEach(SpectralSet.all) { set in
                        Toggle(isOn: binding(for: set.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(set.title)
                                Text("\(set.carrierCount) 子载波 · \(set.dataSymbols) 数据符号 · \(String(format: "%.0f", set.airtimeMs)) ms/包")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("不选任何集合时使用全部 7 组。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("同步到 Watch") { model.syncConfig() }
                    Text("场景、距离、备注和集合会一起同步；水下没有蓝牙，开始前同步一次即可。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("配置")
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { model.config.activeSets.contains { $0.id == id } },
            set: { isOn in
                var ids = model.config.activeSets.map(\.id)
                if isOn {
                    if !ids.contains(id) { ids.append(id) }
                } else {
                    ids.removeAll { $0 == id }
                }
                model.config.setIDs = ids
            }
        )
    }
}

// MARK: - 日志

private struct LogScreen: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationStack {
            List {
                Section("当前日志") {
                    if model.logText.isEmpty {
                        Text("还没有日志").foregroundStyle(.secondary)
                    } else {
                        Text(model.logText)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    ShareLink(item: model.logURL) {
                        Label("导出当前日志", systemImage: "square.and.arrow.up")
                    }
                    Button("刷新", action: model.reloadLog)
                }
                Section("Documents") {
                    ForEach(RunLog.documentFiles(), id: \.path) { url in
                        ShareLink(item: url) {
                            Text(url.lastPathComponent).font(.caption)
                        }
                    }
                    Button("一键清理扫描文件", role: .destructive) {
                        model.clearResultFiles()
                    }
                }
            }
            .navigationTitle("日志")
            .onAppear(perform: model.reloadLog)
        }
    }
}
