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

                Text("系统音量 \(Int((model.outputVolume * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(model.outputVolume < 0.95 ? .orange : .secondary)
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
                }

                Text("开始后有 3 秒准备时间；发送结束前请保持手表在水里/测试位置。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
        .onAppear {
            model.refreshOutputVolume()
        }
        .onChange(of: scenePhase) { _, phase in
            model.noteScenePhase(phase)
        }
    }
}
