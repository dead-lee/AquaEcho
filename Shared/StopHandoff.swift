import Foundation

/// 停止收尾必须离开调用线程；慢的 finish 不得阻塞主线程。
public enum StopHandoff {
    public static func run<Snapshot, Result>(
        queue: DispatchQueue,
        snapshot: @escaping () -> Snapshot,
        finish: @escaping (Snapshot) -> Result,
        completion: @escaping (Result) -> Void
    ) {
        queue.async {
            let snap = snapshot()
            let result = finish(snap)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}
