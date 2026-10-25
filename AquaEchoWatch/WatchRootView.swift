import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var offset: CGFloat = 0
    @State private var gestureOrigin: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
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
            Text("旋转数码表冠调系统音量；手指上下滑动界面。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.outputVolume < 0.99 {
                Text("系统音量不足 100%，现在不会发波；请先把表冠转到最大。")
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            }
        }
        .offset(y: offset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ViewportHeightKey.self, value: proxy.size.height)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(fingerScroll)
        .onPreferenceChange(ContentHeightKey.self) { height in
            contentHeight = height
            offset = clamped(offset)
            gestureOrigin = offset
        }
        .onPreferenceChange(ViewportHeightKey.self) { height in
            viewportHeight = height
            offset = clamped(offset)
            gestureOrigin = offset
        }
        .onAppear {
            offset = 0
            gestureOrigin = 0
            model.noteScenePhase(scenePhase)
            model.prepareAudioSession()
            model.refreshOutputVolume()
        }
        .onChange(of: scenePhase) { _, phase in
            model.noteScenePhase(phase)
        }
        .alert("系统音量不足", isPresented: $model.volumeBlocked) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请旋转数码表冠把系统音量调到 100%。当前 \(Int((model.outputVolume * 100).rounded()))%。")
        }
    }

    private var fingerScroll: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard contentHeight > viewportHeight else { return }
                offset = clamped(gestureOrigin + value.translation.height)
            }
            .onEnded { _ in
                gestureOrigin = offset
            }
    }

    private func clamped(_ proposed: CGFloat) -> CGFloat {
        let limit = min(0, viewportHeight - contentHeight)
        return min(0, max(limit, proposed))
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
