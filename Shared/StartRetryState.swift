import Foundation

/// start 发送失败才进入 pending；watchReady 只用于诊断，不能单独制造 pending。
public struct StartRetryState {
    public private(set) var pending = false

    public init() {}

    public mutating func record(sent: Bool) {
        pending = !sent
    }

    public mutating func clear() {
        pending = false
    }
}
