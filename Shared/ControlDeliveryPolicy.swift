import Foundation

/// 不可达时控制命令排队，而不是丢弃；仍然没有 ack。
public enum ControlDeliveryPolicy {
    public static func shouldQueue(isReachable: Bool) -> Bool {
        !isReachable
    }
}
