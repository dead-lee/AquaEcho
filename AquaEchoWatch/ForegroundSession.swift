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
    var onStopSound: (() -> Void)?

    private var session: WKExtendedRuntimeSession?
    private var userEnded = false

    func startIfNeeded() {
        guard !userEnded else { return }
        if let session, session.state == .running || session.state == .scheduled || session.state == .notStarted {
            return
        }
        let next = WKExtendedRuntimeSession()
        next.delegate = self
        session = next
        next.start()
        status = "正在申请前台"
    }

    /// 上一次若已因停止或表冠离开而结束，下次发送前再开一个 self-care 会话。
    func ensureRunning() {
        userEnded = false
        startIfNeeded()
    }

    func noteScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active, .inactive, .background:
            break
        @unknown default:
            break
        }
    }

    func endBecauseUserStoppedOrLeft() {
        guard !userEnded else { return }
        userEnded = true
        running = false
        status = "已结束前台保持"
        session?.invalidate()
        session = nil
    }

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            self.running = true
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
            self.sessionDidInvalidate(reason, detail: error?.localizedDescription)
        }
    }

    private func sessionDidInvalidate(_ reason: WKExtendedRuntimeSessionInvalidationReason, detail: String?) {
        running = false
        session = nil
        switch reason {
        case .resignedFrontmost:
            onEvent?("按数码表冠离开应用，invalidate 并停止发声")
            onStopSound?()
            endBecauseUserStoppedOrLeft()
        case .none:
            status = "已结束前台保持"
        case .expired, .sessionInProgress, .suppressedBySystem, .error:
            if !userEnded {
                status = "前台保持中"
                onEvent?("系统结束了延长运行（\(Self.name(reason))\(detail.map { "：\($0)" } ?? "")）。熄屏、变暗、返回菜单不会因此调用 invalidate")
            }
        @unknown default:
            break
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
