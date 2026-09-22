import SwiftUI

@main
struct AIUsageIOSApp: App {
    @StateObject private var store = IOSUsageStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            IOSDashboardView()
                .environmentObject(store)
                .task { await store.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store.refresh(force: true) }
        }
    }
}
