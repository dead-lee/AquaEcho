import Foundation
import WatchConnectivity

final class WatchLink: NSObject, WCSessionDelegate {
    var onEnvelope: ((WCEnvelope) -> Void)?
    var onReachable: ((Bool) -> Void)?
    var onFileTransferFinished: ((String, String?) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    @discardableResult
    func send(_ envelope: WCEnvelope) -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        let payload = WCCodec.encode(envelope)
        guard session.activationState == .activated else { return false }
        if envelope.kind == .log {
            guard session.isReachable else { return false }
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
            return true
        }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
        return true
    }

    @discardableResult
    func sendFile(_ url: URL) -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        guard session.activationState == .activated else { return false }
        session.transferFile(url, metadata: [
            "kind": "watchTx",
            "name": url.lastPathComponent
        ])
        return true
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

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let name = fileTransfer.file.fileURL.lastPathComponent
        let message = error?.localizedDescription
        DispatchQueue.main.async {
            self.onFileTransferFinished?(name, message)
        }
    }

    private func deliver(_ message: [String: Any]) {
        guard let envelope = WCCodec.decode(message) else { return }
        DispatchQueue.main.async {
            self.onEnvelope?(envelope)
        }
    }
}
