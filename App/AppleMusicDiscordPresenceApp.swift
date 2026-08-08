import SwiftUI

@main
struct AppleMusicDiscordPresenceApp: App {
    @StateObject private var model = PresenceViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
