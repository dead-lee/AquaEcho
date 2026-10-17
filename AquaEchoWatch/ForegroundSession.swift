import Foundation
import SwiftUI
import WatchKit

/// sessionType 固定为 self-care（Info.plist `WKBackgroundModes`）。
/// 当前 SDK 的 `WKExtendedRuntimeSession()` 不接收 sessionType 参数。
@MainActor
final class ForegroundSession: NSObject, ObservableObject, WKExtendedRuntimeSessionDelegate {
    static let sessionType = "selfCare"

    @Published private(set) var status = "正在申请前台"
    @Published private(set) var running = false

    var onEvent: ((String) -> Void)?
    var onStopSound: ((String) -> Void)?

    private var session: WKExtendedRuntimeSession?
    private var allowedToStart = true
    private var scenePhase: ScenePhase = .inactive
    private var startRequestedAt: Date?

    func setAllowedToStart(_ value: Bool) {
        allowedToStart = value
        onEvent?("延长运行允许启动=\(value ? "是" : "否")")
    }

    func startIfNeeded() {
        guard allowedToStart else {
            onEvent?("延长运行未启动：当前不允许")
            return
        }
        if let session {
            switch session.state {
            case .running:
                onEvent?("延长运行已在运行，跳过")
                return
            case .scheduled, .notStarted:
                let waited = Date().timeIntervalSince(startRequestedAt ?? .distantPast)
                if waited < 1 {
                    onEvent?(String(
                        format: "延长运行等待开始 state=%@ 已等待 %.2f 秒",
                        locale: Locale(identifier: "en_US_POSIX"),
                        Self.stateName(session.state),
                        waited
                    ))
                    return
                }
                onEvent?("延长运行 \(Self.stateName(session.state)) 超过 1 秒仍未运行，作废后重开")
                replaceSession(dropping: session)
                return
            case .invalid:
                onEvent?("延长运行已失效，重新申请")
                self.session = nil
            @unknown default:
                onEvent?("延长运行未知状态 rawValue=\(session.state.rawValue)，作废后重开")
                replaceSession(dropping: session)
                return
            }
        }
        beginSession()
    }

    private func replaceSession(dropping old: WKExtendedRuntimeSession) {
        guard beginSession() else { return }
        old.invalidate()
    }

    /// 只有场景已经是 active 才创建会话并 `start()`。否则不创建。
    @discardableResult
    private func beginSession() -> Bool {
        guard scenePhase == .active else {
            onEvent?("延长运行延迟：App 非 active")
            return false
        }
        let next = WKExtendedRuntimeSession()
        next.delegate = self
        session = next
        startRequestedAt = Date()
        next.start()
        status = "正在申请前台"
        onEvent?("已调用 start()，调用后 state=\(Self.stateName(next.state)) rawValue=\(next.state.rawValue)")
        return true
    }

    /// 发送前允许启动，并在当前已经 active 时申请会话。
    func ensureRunning() {
        setAllowedToStart(true)
        startIfNeeded()
    }

    func noteScenePhase(_ phase: ScenePhase) {
        scenePhase = phase
        let state = session.map { "\(Self.stateName($0.state)) rawValue=\($0.state.rawValue)" } ?? "无会话"
        onEvent?("场景阶段=\(Self.phaseName(phase)) 会话=\(state) 前台保持=\(running ? "是" : "否")")
    }

    func endBecauseUserStoppedOrLeft() {
        running = false
        status = "已结束前台保持"
        let current = session
        session = nil
        current?.invalidate()
    }

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            self.running = true
            self.startRequestedAt = nil
            self.status = "前台保持中"
            self.onEvent?("延长运行已开始（selfCare）。熄屏、变暗、返回菜单不结束会话")
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        Task { @MainActor in
            let detail = (error as NSError?).map { "domain=\($0.domain) code=\($0.code) \($0.localizedDescription)" }
            self.sessionDidInvalidate(extendedRuntimeSession, reason, detail: detail)
        }
    }

    private func sessionDidInvalidate(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        _ reason: WKExtendedRuntimeSessionInvalidationReason,
        detail: String?
    ) {
        guard session === extendedRuntimeSession || session == nil else {
            onEvent?("忽略已替换会话的失效 reason=\(Self.rawName(reason)) rawValue=\(reason.rawValue)")
            return
        }
        running = false
        if session === extendedRuntimeSession {
            session = nil
        }
        switch reason {
        case .resignedFrontmost:
            setAllowedToStart(false)
            onEvent?("按数码表冠离开应用，invalidate 并停止发声")
            onStopSound?("resignedFrontmost rawValue=\(reason.rawValue)")
            status = "已结束前台保持"
        case .none:
            status = "已结束前台保持"
        case .sessionInProgress:
            status = "前台保持中"
            onEvent?("系统结束了延长运行（\(Self.name(reason))\(detail.map { "：\($0)" } ?? "")）。熄屏、变暗、返回菜单不会因此调用 invalidate")
        case .error where Self.isNotActiveRejection(detail):
            onEvent?("延长运行被系统拒绝（非 active） \(Self.errorText(detail))")
        case .expired, .suppressedBySystem, .error:
            onEvent?("延长运行失效 reason=\(Self.rawName(reason)) rawValue=\(reason.rawValue) \(Self.errorText(detail))")
            status = "前台保持中"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard self.allowedToStart, self.scenePhase == .active else {
                    self.onEvent?("延长运行未重启：允许启动=\(self.allowedToStart ? "是" : "否") 场景=\(Self.phaseName(self.scenePhase))")
                    return
                }
                self.startIfNeeded()
            }
        @unknown default:
            break
        }
    }

    private static func isNotActiveRejection(_ detail: String?) -> Bool {
        guard let detail else { return false }
        return detail.range(of: #"code=3(\D|$)"#, options: .regularExpression) != nil
    }

    private static func phaseName(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private static func stateName(_ state: WKExtendedRuntimeSessionState) -> String {
        switch state {
        case .notStarted: return "notStarted"
        case .scheduled: return "scheduled"
        case .running: return "running"
        case .invalid: return "invalid"
        @unknown default: return "unknown"
        }
    }

    private static func errorText(_ detail: String?) -> String {
        detail.map { "detail=\($0)" } ?? "detail=nil"
    }

    private static func rawName(_ reason: WKExtendedRuntimeSessionInvalidationReason) -> String {
        switch reason {
        case .none: return "none"
        case .sessionInProgress: return "sessionInProgress"
        case .expired: return "expired"
        case .resignedFrontmost: return "resignedFrontmost"
        case .suppressedBySystem: return "suppressedBySystem"
        case .error: return "error"
        @unknown default: return "unknown"
        }
    }

    private static func name(_ reason: WKExtendedRuntimeSessionInvalidationReason) -> String {
        switch reason {
        case .none: return "正常结束"
        case .sessionInProgress: return "已有会话"
        case .expired: return "到期"
        case .resignedFrontmost: return "失去最前台"
        case .suppressedBySystem: return "系统限制"
        case .error: return "错误"
        @unknown default: return "未知"
        }
    }
}
