import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("AquaEcho").font(.headline)
                    Spacer()
                    Text("构建 \(AppBuild.number)").font(.caption2).foregroundStyle(.secondary)
                }

                Text(model.foregroundRunning ? "前台保持中" : model.foregroundStatus)
                    .font(.caption2)
                    .foregroundStyle(model.foregroundRunning ? .green : .orange)
                Text(model.reachable ? "iPhone 已连接" : "iPhone 未连接")
                    .font(.caption)
                    .foregroundStyle(model.reachable ? .green : .secondary)
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

                Text("系统音量 \(Int((model.outputVolume * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(model.outputVolume < 0.99 ? .orange : .secondary)
                Text("按侧边按钮打开控制中心，把系统音量调到 100%；表冠只用于滚动。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.outputVolume < 0.99 {
                    Text("系统音量不足 100%，现在不会发波。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.isRunning {
                    Button("停止", role: .destructive) {
                        model.stop(reason: "用户按停止按钮")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("开始", action: model.requestStart)
                        .buttonStyle(.borderedProminent)
                }

                Text("先在 iPhone 上点“开始测试”；手机会同时请求手表开始。开始后手表只播放，不录音；结束时请保持手表在测试位置。")
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
        .alert("系统音量不足", isPresented: $model.volumeBlocked) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请用控制中心把系统音量调到 100%。当前 \(Int((model.outputVolume * 100).rounded()))%。")
        }
    }
}
