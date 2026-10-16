import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            TestScreen()
                .tabItem { Label("测试", systemImage: "waveform") }
            ResultsScreen()
                .tabItem { Label("结果", systemImage: "list.number") }
            ConfigScreen()
                .tabItem { Label("配置", systemImage: "slider.horizontal.3") }
            LogScreen()
                .tabItem { Label("日志", systemImage: "doc.text") }
        }
    }
}

struct TestScreen: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationStack {
            List {
                Section("连接") {
                    LabeledContent("Watch") {
                        Text(model.reachable ? "已连接" : (model.activated ? "未打开" : "会话未激活"))
                            .foregroundStyle(model.reachable ? .green : .secondary)
                    }
                    LabeledContent("模式", value: model.config.mode.title)
                    LabeledContent("频率对", value: "\(model.config.plannedPairs().count) 组")
                    LabeledContent("预计时长", value: duration(model.config.estimatedTestSeconds))
                }
                Section("本次") {
                    Text(model.status)
                    if model.isRunning {
                        LabeledContent("已收到", value: "\(model.receivedCount) / \(model.expectedCount)")
                        ProgressView()
                    }
                    if let error = model.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section {
                    Text("测试时请把 Watch 音量调到最大，让扬声器靠近 iPhone 底部麦克风。近超声在空气里衰减很快；潜水或隔着外壳时，把两台设备放在真实相对位置再开始。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("AquaEcho")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if model.isRunning {
                        Button("停止并评分", role: .destructive, action: model.stopTest)
                    } else {
                        Button("开始测试") {
                            Task { await model.startTest() }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
        }
    }

    private func duration(_ seconds: Double) -> String {
        if seconds < 90 { return "\(Int(seconds.rounded())) 秒" }
        return String(format: "%.1f 分钟", locale: Locale(identifier: "en_US_POSIX"), seconds / 60)
    }
}

struct ResultsScreen: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationStack {
            Group {
                if model.pairs.isEmpty {
                    ContentUnavailableView("还没有结果", systemImage: "ear", description: Text("完成一次测试后，这里会按总分列出频率组合。"))
                } else {
                    List {
                        if let best = model.pairs.first(where: \.isRecommended) {
                            Section("推荐（总分 ≥ 80）") {
                                ForEach(model.pairs.filter(\.isRecommended)) { pair in
                                    NavigationLink {
                                        PairDetailView(pair: pair)
                                    } label: {
                                        PairRow(pair: pair, highlighted: pair.id == best.id)
                                    }
                                }
                            }
                        }
                        Section(model.pairs.contains(where: \.isRecommended) ? "其他频率对" : "全部频率对") {
                            ForEach(model.pairs.filter { !$0.isRecommended }) { pair in
                                NavigationLink {
                                    PairDetailView(pair: pair)
                                } label: {
                                    PairRow(pair: pair, highlighted: false)
                                }
                            }
                        }
                        if let url = model.csvURL {
                            Section("CSV") {
                                Text(url.lastPathComponent)
                                ShareLink(item: url) { Label("导出 CSV", systemImage: "square.and.arrow.up") }
                                Text("文件在 App 的 Documents 里。访达或「文件」App 都能直接看到。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("结果")
        }
    }
}

struct PairRow: View {
    var pair: PairScore
    var highlighted: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(pair.label).font(.headline)
                Text("SNR \(format(pair.meanSNRdB)) dB · 通过 \(format(pair.passRate * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(pair.score.total)")
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(pair.isRecommended ? Color.green : Color.primary)
        }
        .listRowBackground(highlighted ? Color.green.opacity(0.12) : nil)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

struct PairDetailView: View {
    var pair: PairScore

    var body: some View {
        List {
            Section {
                LabeledContent("总分", value: "\(pair.score.total) / 100")
                LabeledContent("平均 SNR", value: "\(num(pair.meanSNRdB, 2)) dB → \(pair.score.snr) / 40")
                LabeledContent("双频区分度", value: "\(num(pair.ratioDB, 2)) dB → \(pair.score.separation) / 20")
                LabeledContent("通过率", value: "\(num(pair.passRate * 100, 1))% → \(pair.score.passRate) / 40")
            }
            Section("每次发送") {
                ForEach(pair.transmissions) { transmission in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("#\(transmission.packet.sequence)  \(transmission.packet.payloadHex)")
                            .font(.system(.body, design: .monospaced))
                        Text("Watch \(stamp(transmission.packet.watchSendDate))")
                            .font(.caption)
                        Text("iPhone \(transmission.phoneReceiveDate.map(stamp) ?? "未检出")")
                            .font(.caption)
                        Text("本包 SNR \(num(transmission.packetSNRdB, 1)) dB · \(transmission.passed ? "通过" : "未通过")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(pair.label)
    }

    private func num(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

struct ConfigScreen: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationStack {
            Form {
                Picker("模式", selection: $model.config.mode) {
                    ForEach(TestMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Section("扫描") {
                    numberField("下限", unit: "Hz", value: $model.config.freqMinHz)
                    numberField("上限", unit: "Hz", value: $model.config.freqMaxHz)
                    numberField("步进", unit: "Hz", value: $model.config.stepHz)
                    numberField("频率间隔", unit: "Hz", value: $model.config.pairSeparationHz)
                    Text("频率间隔是这一对 OFDM 的带宽，至少 1 kHz。扫描从下限开始，每次前进一个步进。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("包") {
                    numberField("符号时长", unit: "ms", value: $model.config.symbolDurationMs)
                    numberField("循环前缀", unit: "ms", value: $model.config.cyclicPrefixMs)
                    numberField("静音时长", unit: "ms", value: $model.config.silenceDurationMs)
                    HStack {
                        Text("重复次数")
                        Spacer(minLength: 8)
                        Stepper(value: $model.config.repeats, in: 1...30) {
                            Text("\(model.config.repeats)")
                                .monospacedDigit()
                        }
                        .fixedSize()
                        Text("次")
                            .foregroundStyle(.secondary)
                    }
                    numberField("前导静音", unit: "ms", value: $model.config.leadSilenceMs)
                    numberField("结尾静音", unit: "ms", value: $model.config.trailSilenceMs)
                    Text("符号时长是有用符号长度。循环前缀加在每个符号前面。前导是 8 段 Naiser。静音时长是前导和第一个符号之间的间隔。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("将测试", value: "\(model.config.normalized.plannedPairs().count) 组频率")
                    Button("同步到 Watch") { model.syncConfig() }
                }
            }
            .navigationTitle("配置")
            .onAppear(perform: alignFrequencyRange)
            .onChange(of: model.config.mode) { _, _ in
                alignFrequencyRange()
            }
        }
    }

    private func alignFrequencyRange() {
        model.config.freqMinHz = 15_000
        model.config.freqMaxHz = 20_000
    }

    private func numberField(_ title: String, unit: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 140)
            Text(unit)
                .foregroundStyle(.secondary)
        }
    }
}

struct LogScreen: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationStack {
            List {
                Section(model.logURL?.lastPathComponent ?? "当前日志") {
                    if model.logText.isEmpty {
                        Text("还没有日志")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(model.logText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if let url = model.logURL {
                        ShareLink(item: url) {
                            Label("导出当前日志", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("刷新", action: model.reloadLog)
                }
                Section("Documents 里的日志、CSV 和调试录音") {
                    ForEach(RunLog.documentFiles(), id: \.path) { url in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(url.lastPathComponent)
                                .font(.caption)
                            ShareLink(item: url) {
                                Text("导出")
                            }
                        }
                    }
                    Button("一键清理", role: .destructive) { model.clearResultFiles() }
                    if let message = model.cleanupMessage {
                        Text(message)
                    }
                    Text("文件在 App 的 Documents 目录。用数据线连上 Mac 后，在访达侧边栏打开这台 iPhone 里的 AquaEcho；或在「文件」App 的「我的 iPhone」里查看。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("日志")
            .onAppear(perform: model.reloadLog)
        }
    }
}
