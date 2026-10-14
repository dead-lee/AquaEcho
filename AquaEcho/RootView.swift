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
                                Text("文件在 App 的 Documents 里。用数据线连接 Mac 后，在访达侧边栏点这台 iPhone，打开 AquaEcho，把 CSV 拖到桌面。")
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
                Text("SNR \(format(pair.meanSNRdB)) dB · 波动 \(format(pair.stabilityCV * 100))%")
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
                LabeledContent("平均 SNR", value: "\(num(pair.meanSNRdB, 2)) dB → \(pair.score.snr) / 45")
                LabeledContent("稳定性", value: "CV \(num(pair.stabilityCV, 3)) → \(pair.score.stability) / 20")
                LabeledContent("双频区分度", value: "\(num(pair.ratioDB, 2)) dB → \(pair.score.separation) / 15")
                if let rate = pair.decodeRate {
                    LabeledContent("ggwave 解码", value: "\(num(rate * 100, 1))% → \(pair.score.decodability) / 20")
                } else {
                    LabeledContent("可解码性", value: "由 SNR 与稳定性折算 → \(pair.score.decodability) / 20")
                }
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
                        Text("本包 SNR \(num(transmission.packetSNRdB, 1)) dB")
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
                    numberField("下限 Hz", value: $model.config.freqMinHz)
                    numberField("上限 Hz", value: $model.config.freqMaxHz)
                    numberField("步进 Hz", value: $model.config.stepHz)
                    if model.config.mode == .cpfsk {
                        numberField("频率间隔 Hz", value: $model.config.pairSeparationHz)
                        Text("两个音至少相隔 1 kHz。实际扫描会从下限开始，每次前进一个步进。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("ggwave 协议", selection: $model.config.ggwaveProtocol) {
                            ForEach(GGWaveProtocolKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        Stepper("波形幅度 \(model.config.ggwaveVolume)", value: $model.config.ggwaveVolume, in: 1...50)
                        Text("幅度上限是 50，避免多音叠加削波。播放前会把峰值归一化到满幅。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("包") {
                    if model.config.mode == .cpfsk {
                        numberField("符号时长 ms", value: $model.config.symbolDurationMs)
                    }
                    Stepper("重复次数 \(model.config.repeats)", value: $model.config.repeats, in: 1...30)
                    numberField("前导静音 ms", value: $model.config.leadSilenceMs)
                    numberField("结尾静音 ms", value: $model.config.trailSilenceMs)
                    Text("每次发送都会重新生成 8 字节随机内容，序号写在 CSV 里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("将测试", value: "\(model.config.normalized.plannedPairs().count) 组频率")
                    Button("同步到 Watch") { model.syncConfig() }
                }
            }
            .navigationTitle("配置")
        }
    }

    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
            .keyboardType(.decimalPad)
    }
}
