import SwiftUI
import WatchKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidBecomeActive() {
        Task { @MainActor in
            WatchActivation.onDidBecomeActive?()
        }
    }

    func applicationWillResignActive() {
        Task { @MainActor in
            WatchActivation.onWillResignActive?()
        }
    }

    func applicationDidEnterBackground() {
        Task { @MainActor in
            WatchActivation.onDidEnterBackground?()
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
