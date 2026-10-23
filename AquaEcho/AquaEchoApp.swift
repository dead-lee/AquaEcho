import SwiftUI

@main
struct AquaEchoApp: App {
    @StateObject private var model = ScanModel()

    var body: some Scene {
        WindowGroup {
            ScanRootView()
                .environmentObject(model)
        }
    }
}
