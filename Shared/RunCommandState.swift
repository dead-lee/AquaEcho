import Foundation

/// 按手机提交顺序消费 start/stop；不做幂等合并。
public struct RunCommandState {
    public private(set) var generation = 0
    public private(set) var running = false

    public init() {}

    @discardableResult
    public mutating func applyStart() -> Int {
        generation += 1
        running = true
        return generation
    }

    public mutating func applyStop() {
        running = false
    }
}
