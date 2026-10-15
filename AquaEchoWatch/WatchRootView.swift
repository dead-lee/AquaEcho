import SwiftUI

struct WatchRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.foreground.running ? "前台保持中" : model.foregroundStatus)
                    .font(.caption2)
                    .foregroundStyle(model.foreground.running ? .green : .orange)
                Text(model.reachable ? "iPhone 已连接" : "iPhone 未连接")
                    .font(.caption)
                    .foregroundStyle(model.reachable ? .green : .secondary)
                Text(model.config.mode.title)
                    .font(.headline)
                Text("\(model.config.plannedPairs().count) 组 · 重复 \(model.config.repeats) 次")
                    .font(.caption2)
                Text(volumeText)
                    .font(.caption2)
                    .foregroundStyle(model.outputVolume < 0.95 ? .orange : .secondary)
                Text(model.status)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isRunning {
                    ProgressView()
                    Button("停止", role: .destructive, action: model.stop)
                } else {
                    Button("开始", action: model.requestStart)
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDisabled(false)
        .onAppear { model.noteScenePhase(scenePhase) }
        .onChange(of: scenePhase) { _, phase in
            model.noteScenePhase(phase)
        }
    }

    private var volumeText: String {
        let percent = Int((model.outputVolume * 100).rounded())
        if model.outputVolume < 0.95 {
            return "音量不足，请旋转数码表冠调到最大"
        }
        return "音量 \(percent)%"
    }
}
