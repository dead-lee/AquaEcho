import Foundation
import WatchConnectivity

final class WatchLink: NSObject, WCSessionDelegate {
    var onEnvelope: ((WCEnvelope) -> Void)?
    var onReachable: ((Bool) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(_ envelope: WCEnvelope) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        let payload = WCCodec.encode(envelope)
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.onReachable?(session.isReachable)
            if let envelope = WCCodec.decode(session.receivedApplicationContext) {
                self.onEnvelope?(envelope)
            }
        }
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
