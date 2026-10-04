import SwiftUI

@main
struct MediaHubApp: App {
    @State private var store = AddonStore()
    @State private var history = WatchHistory()
    @State private var simkl = SimklStore()
    @State private var pins = PinnedSources()

    var body: some Scene {
        WindowGroup {
            RootView().environment(store).environment(history).environment(simkl).environment(pins)
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var phase
    @Environment(SimklStore.self) private var simkl

    var body: some View {
        // System TabView gives Liquid Glass tab bar for free.
        TabView {
            Tab("Home", systemImage: "house.fill") { HomeView() }
            Tab("Library", systemImage: "books.vertical.fill") { LibraryView() }
            Tab("Settings", systemImage: "gearshape.fill") { SettingsView() }
            Tab(role: .search) { SearchView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .task { await simkl.sync() }
        .onChange(of: phase) { _, p in if p == .active { Task { await simkl.sync() } } }
    }
}
