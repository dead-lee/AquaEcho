import SwiftUI

struct WatchRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: WatchModel
    @State private var offset: CGFloat = 0
    @State private var gestureOrigin: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("构建 \(AppBuild.number)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(model.foreground.running ? "前台保持中" : model.foregroundStatus)
                .font(.caption2)
                .foregroundStyle(model.foreground.running ? .green : .orange)
            Text(model.reachable ? "iPhone 已连接" : "iPhone 未连接")
                .font(.caption)
                .foregroundStyle(model.reachable ? .green : .secondary)
            Text(model.config.mode.title)
                .font(.headline)
            Text("\(HzFormat.string(model.config.frequency.candidateLowHz))–\(HzFormat.string(model.config.frequency.candidateHighHz)) Hz · 重复 \(model.config.repeats) 次")
                .font(.caption2)
            Text("音量 \(volumePercent)%")
                .font(.caption2)
                .foregroundStyle(model.playbackVolume < 0.95 ? .orange : .secondary)
            if model.playbackVolume < 0.95 {
                Text("音量不足，请旋转数码表冠调到最大")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.status)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if model.isRunning {
                ProgressView()
                Button("停止", role: .destructive) {
                    model.stop(reason: "用户按停止按钮")
                }
            } else {
                Button("开始", action: model.requestStart)
                    .buttonStyle(.borderedProminent)
            }
        }
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
        .focusable(true)
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
        .onAppear { model.noteScenePhase(scenePhase) }
        .onChange(of: scenePhase) { _, phase in
            model.noteScenePhase(phase)
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

    private var volumePercent: Int {
        Int((model.playbackVolume * 100).rounded())
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
