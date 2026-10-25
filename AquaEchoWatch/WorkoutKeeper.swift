import Foundation
import HealthKit

/// 手表端保活：workout-processing 后台会话。
/// 只负责让 App 在低腕/熄屏后仍是前台 App；不保存 workout 数据，不碰音频。
@MainActor
final class WorkoutKeeper: NSObject, ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var isStarting = false
    @Published private(set) var status = "未开始"

    var onEvent: ((String) -> Void)?
    var onReady: (() -> Void)?
    var onEnded: (() -> Void)?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var startedAt: Date?

    func startIfNeeded() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "HealthKit 不可用"
            onEvent?("错误：HealthKit 不可用")
            return
        }
        guard !running, !isStarting else { return }

        isStarting = true
        status = "正在启动 workout 会话"
        onEvent?("workout 启动中")

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .outdoor

        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: store,
                workoutConfiguration: configuration
            )
            session.delegate = self
            self.session = session
            self.builder = builder
            self.startedAt = Date()
            session.startActivity(with: Date())
            builder.beginCollection(withStart: Date()) { success, error in
                Task { @MainActor in
                    if success {
                        self.onEvent?("workout builder beginCollection 成功")
                    } else {
                        self.onEvent?("错误 builder beginCollection 失败 \(error?.localizedDescription ?? "unknown")")
                    }
                }
            }
            status = "workout 启动中"
            onEvent?("已调用 startActivity + beginCollection，等待 running")
        } catch {
            isStarting = false
            status = "workout 启动失败"
            onEvent?("错误 workout 启动失败 \(error.localizedDescription)")
        }
    }

    func end() {
        guard let session else {
            running = false
            isStarting = false
            status = "已结束"
            onEvent?("workout 结束：没有会话")
            onEnded?()
            return
        }
        if let builder {
            builder.endCollection(withEnd: Date()) { _, _ in
                builder.discardWorkout()
            }
        }
        self.builder = nil
        session.end()
        self.session = nil
        running = false
        isStarting = false
        status = "已结束"
        onEvent?("已调用 workout end() + discardWorkout")
    }

    /// 从后台被手机唤起后，如果系统已经结束会话，允许重建。
    func recoverIfNeeded() async {
        guard !running, !isStarting else { return }
        await startIfNeeded()
    }

    var startedRecently: Bool {
        guard let startedAt else { return false }
        return Date().timeIntervalSince(startedAt) < 3
    }
}

extension WorkoutKeeper: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            self.onEvent?("workout 状态 \(fromState.rawValue) → \(toState.rawValue)")
            switch toState {
            case .running:
                self.running = true
                self.isStarting = false
                self.status = "前台保持中"
                self.onReady?()
            case .ended:
                self.running = false
                self.isStarting = false
                self.status = "已结束"
                self.session = nil
                self.onEnded?()
            case .paused:
                self.status = "workout 暂停"
            case .stopped:
                self.status = "workout 停止"
            case .prepared:
                self.status = "workout 准备"
            case .notStarted:
                self.status = "workout 未开始"
            @unknown default:
                self.status = "workout 状态未知"
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.running = false
            self.isStarting = false
            self.status = "workout 失败"
            self.session = nil
            self.builder = nil
            self.onEvent?("错误 workout 失败 \(error.localizedDescription)")
            self.onEnded?()
        }
    }
}
