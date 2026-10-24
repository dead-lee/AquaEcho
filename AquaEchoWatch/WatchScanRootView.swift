import SwiftUI

struct WatchScanRootView: View {
    @EnvironmentObject private var model: WatchScanModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("AquaEcho 扫描").font(.headline)
                    Spacer()
                    Text("构建 \(AppBuild.number)").font(.caption2).foregroundStyle(.secondary)
                }

                Text(model.runLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(model.sets.map(\.id).joined(separator: ",")) · \(model.packetsPerSet) 包/组 · 共 \(model.totalPackets) 包")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(model.status)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                if !model.progressText.isEmpty {
                    Text(model.progressText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text("前台保持 \(model.foregroundRunning ? "中" : "否") · 系统音量 \(Int((model.outputVolume * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(model.foregroundRunning ? .green : .secondary)
                if model.outputVolume < 0.95 {
                    Text("音量不足，请先把系统音量调大")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.isRunning {
                    Button("停止", role: .destructive) {
                        model.stop()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("开始扫描") {
                        model.start()
                    }
                    .buttonStyle(.borderedProminent)
                    if model.foregroundRunning {
                        Button("结束前台保持") {
                            model.endForeground()
                        }
                        .font(.caption2)
                    }
                }

                Text("先在 iPhone 上点“开始录音”；手机会同时请求手表开始扫描。开始后有 3 秒准备时间；发送结束前请保持手表在水里/测试位置。手表只播放，不录音。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
        .onAppear {
            model.noteScenePhase(scenePhase)
            model.refreshOutputVolume()
        }
        .onChange(of: scenePhase) { _, phase in
            model.noteScenePhase(phase)
        }
    }
}
