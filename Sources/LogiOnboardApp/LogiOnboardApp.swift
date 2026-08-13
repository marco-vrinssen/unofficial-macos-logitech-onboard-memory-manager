import SwiftUI

@main
struct LogiOnboardApp: App {
    var body: some Scene {
        WindowGroup("Logitech Onboard Memory Manager") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
