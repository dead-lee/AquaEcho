import Foundation

/// 防止 startRecording 在 await 期间被重复进入。
public struct StartAdmission {
    public private(set) var isActive = false

    public init() {}

    public mutating func tryBegin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    public mutating func end() {
        isActive = false
    }
}
