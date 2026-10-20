import SwiftUI

@main
struct STIXRemoteApp: App {
    @StateObject private var store = RemoteChatStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if store.isPaired { RemoteChatView() }
                else { PairingView() }
            }
            .environmentObject(store)
            .tint(Color(red: 0.16, green: 0.42, blue: 0.96))
            .task { await store.start() }
        }
    }
}
