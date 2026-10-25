import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var offset: CGFloat = 0
    @State private var gestureOrigin: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 6) {
                        Text("AquaEcho").font(.headline)
                        Text("构建 \(AppBuild.number)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
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

                    Text("播放音量 \(Int((model.playbackVolume * 100).rounded()))% · 系统 \(Int((model.outputVolume * 100).rounded()))%")
                        .font(.caption2)
                        .foregroundStyle(model.playbackVolume < 0.99 ? .orange : .secondary)
                    Text("旋转表冠调播放音量；系统音量请在控制中心设置。手指上下滑动界面。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.outputVolume < 0.99 {
                        Text("播放音量可用表冠调整；系统音量当前为 \(Int((model.outputVolume * 100).rounded()))%，需要更大请在控制中心设置。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("在 iPhone 上开始/停止测试；手表只播放，不录音。结束时请保持手表在测试位置。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { contentProxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: contentProxy.size.height)
                    }
                }
                .offset(y: offset)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .clipped()
                .contentShape(Rectangle())
                .simultaneousGesture(fingerScroll)
                .onPreferenceChange(ContentHeightKey.self) { height in
                    contentHeight = height
                    offset = clamped(offset, viewport: proxy.size.height)
                    gestureOrigin = offset
                }

                VolumeBar(volume: model.outputVolume * Float(model.playbackVolume))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 4)
                    .padding(.trailing, 5)
                    .allowsHitTesting(false)
            }
            .onAppear {
                viewportHeight = max(proxy.size.height, 1)
                offset = 0
                gestureOrigin = 0
                model.noteScenePhase(scenePhase)
                model.prepareAudioSession()
                model.refreshOutputVolume()
            }
            .onChange(of: proxy.size.height) { _, newHeight in
                viewportHeight = max(newHeight, 1)
                offset = clamped(offset, viewport: newHeight)
                gestureOrigin = offset
            }
        }
        .focusable(true)
        .digitalCrownRotation(
            $model.playbackVolume,
            from: 0.0,
            through: 1.0,
            by: 0.01,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: model.playbackVolume) { _, _ in
            model.applyPlaybackVolume()
        }
        .onChange(of: scenePhase) { _, phase in
            model.noteScenePhase(phase)
        }
        .alert("音量提示", isPresented: $model.volumeBlocked) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("系统音量当前 \(Int((model.outputVolume * 100).rounded()))%；播放音量可以用数码表冠调整。")
        }
    }

    private var fingerScroll: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard contentHeight > viewportHeight else { return }
                offset = clamped(gestureOrigin + value.translation.height, viewport: viewportHeight)
            }
            .onEnded { _ in
                gestureOrigin = offset
            }
    }

    private func clamped(_ proposed: CGFloat, viewport: CGFloat) -> CGFloat {
        let limit = min(0, viewport - contentHeight)
        return min(0, max(limit, proposed))
    }
}

private struct VolumeBar: View {
    let volume: Float

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 6, height: 48)
                Capsule()
                    .fill(volume < 0.99 ? Color.orange : Color.green)
                    .frame(width: 6, height: max(2, 48 * CGFloat(max(0, min(1, volume)))))
            }
            Text("\(Int((volume * 100).rounded()))")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
