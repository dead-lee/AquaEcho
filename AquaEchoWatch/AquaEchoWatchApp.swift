import SwiftUI
import WatchKit
import HealthKit

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

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in
            WatchActivation.pendingWorkoutConfiguration = workoutConfiguration
            WatchActivation.onWorkoutConfiguration?(workoutConfiguration)
        }
    }
}

// @main
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
