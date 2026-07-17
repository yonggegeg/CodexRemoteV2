import SwiftUI

@main
struct CodexRemoteApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var client = RemoteClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(client)
        }
    }
}
