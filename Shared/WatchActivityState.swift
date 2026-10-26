import Foundation

/// watchReady 只是 workout ready；只有 App active 才允许发 start，started 才代表手表真正开始。
public struct WatchActivityState {
    public private(set) var active = false
    public private(set) var started = false

    public init() {}

    public mutating func setActive(_ value: Bool) {
        active = value
    }

    public mutating func resetStarted() {
        started = false
    }

    public mutating func markStarted() {
        guard active else { return }
        started = true
    }

    public var canSendStart: Bool { active }
}
