import SwiftUI
import WatchKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidBecomeActive() {
        Task { @MainActor in
            WatchActivation.onDidBecomeActive?()
        }
    }
}

@main
struct AquaEchoWatchApp: App {
    @StateObject private var model = WatchModel()
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(model)
        }
    }
}
