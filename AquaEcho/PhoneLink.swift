import Foundation
import WatchConnectivity

final class PhoneLink: NSObject, WCSessionDelegate {
    var onEnvelope: ((WCEnvelope) -> Void)?
    var onReachable: ((Bool) -> Void)?
    var onActivated: ((Bool) -> Void)?

    func activate() {
        guard WCSession.isSupported() else {
            onActivated?(false)
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    @discardableResult
    func send(_ envelope: WCEnvelope) -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        let payload = WCCodec.encode(envelope)
        if envelope.kind == .config {
            try? session.updateApplicationContext(payload)
        }
        guard session.activationState == .activated else { return false }
        let control = envelope.kind == .start || envelope.kind == .stop || envelope.kind == .endWorkout
        if control {
            // 单一 FIFO 队列；不检查 reachable，也不与 sendMessage 混用。
            session.transferUserInfo(payload)
            return true
        }
        guard session.isReachable else { return false }
        session.sendMessage(payload, replyHandler: nil) { _ in
            session.transferUserInfo(payload)
        }
        return true
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.onActivated?(activationState == .activated)
            self.onReachable?(session.isReachable)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.onReachable?(session.isReachable)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        deliver(userInfo)
    }

    private func deliver(_ message: [String: Any]) {
        guard let envelope = WCCodec.decode(message) else { return }
        DispatchQueue.main.async {
            self.onEnvelope?(envelope)
        }
    }
}
