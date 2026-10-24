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

                Text("音量 \(Int((model.playbackVolume * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(model.playbackVolume < 0.95 ? .orange : .secondary)
                if model.playbackVolume < 0.95 {
                    Text("音量不足，请旋转数码表冠调到最大")
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
                    if model.foregroundRunning {
                        Button("结束前台保持") {
                            model.endForeground()
                        }
                        .font(.caption2)
                    }
                }

                Text("先在 iPhone 上点“开始测试”；手机会同时请求手表开始。开始后手表只播放，不录音；结束时请保持手表在测试位置。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
        .digitalCrownRotation(
            $model.playbackVolume,
            from: 0.0,
            through: 1.0,
            by: 0.05,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: model.playbackVolume) { _, _ in
            model.applyPlaybackVolume()
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
