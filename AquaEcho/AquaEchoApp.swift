import SwiftUI

@main
struct AquaEchoApp: App {
    @StateObject private var model = PhoneModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}
