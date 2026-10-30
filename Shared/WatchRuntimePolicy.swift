import Foundation

/// 手腕放下、通知或 workout 界面都会让手表短暂 `willResignActive`。
/// 那只是失焦。播放和手机解码都不看这个状态。
/// 只有真正进入后台才停止播放并结束 workout。
public enum WatchRuntimePolicy {
    public enum PlaybackEffect: Equatable {
        case keepPlaying
        case stopAndEndWorkout
    }

    public static func playbackEffect(willResignActive: Bool, didEnterBackground: Bool) -> PlaybackEffect {
        if didEnterBackground { return .stopAndEndWorkout }
        _ = willResignActive
        return .keepPlaying
    }
}
