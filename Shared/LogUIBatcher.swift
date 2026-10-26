import Foundation

/// UI 日志只按固定间隔合流，避免每条 Scan 日志都触发 @Published 更新拖死主线程。
public final class LogUIBatcher {
    private let lock = NSLock()
    private let maxChars: Int
    private let autoFlush: Bool
    private var pending = ""
    private var stored = ""
    private var scheduled = false

    public var onFlush: ((String) -> Void)?

    public init(maxChars: Int = 200_000, autoFlush: Bool = true) {
        self.maxChars = maxChars
        self.autoFlush = autoFlush
    }

    public func append(_ line: String) {
        var shouldSchedule = false
        lock.lock()
        pending.append(line)
        if pending.count > maxChars {
            pending = String(pending.suffix(maxChars))
        }
        if autoFlush && !scheduled {
            scheduled = true
            shouldSchedule = true
        }
        lock.unlock()

        if shouldSchedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.flush()
            }
        }
    }

    public func flushNow() {
        flush()
    }

    public func setText(_ value: String) {
        lock.lock()
        stored = value
        pending = ""
        scheduled = false
        let snapshot = stored
        lock.unlock()
        onFlush?(snapshot)
    }

    public func clear() {
        setText("")
    }

    public var text: String {
        lock.lock()
        defer { lock.unlock() }
        return stored + pending
    }

    private func flush() {
        lock.lock()
        let chunk = pending
        pending = ""
        scheduled = false
        if !chunk.isEmpty {
            stored.append(chunk)
            if stored.count > maxChars {
                stored = String(stored.suffix(maxChars))
            }
        }
        let snapshot = stored
        lock.unlock()

        if !chunk.isEmpty {
            onFlush?(snapshot)
        }
    }
}
