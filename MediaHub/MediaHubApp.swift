import SwiftUI

/// One place for the app's look. Change `accent` / `accent2` to re-colour progress bars, tints and glows.
enum Theme {
    static let accent = Color(red: 0.49, green: 0.36, blue: 1.00)    // electric violet
    static let accent2 = Color(red: 1.00, green: 0.36, blue: 0.55)   // hot pink
    static var gradient: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing)
    }
    /// Colourful glows and hero art read best on black. Set to false to follow the system appearance.
    static let forceDark = true
}

@main
struct MediaHubApp: App {
    @State private var store = AddonStore()
    @State private var history = WatchHistory()
    @State private var simkl = SimklStore()
    @State private var pins = PinnedSources()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store).environment(history).environment(simkl).environment(pins)
                .tint(Theme.accent)
                .preferredColorScheme(Theme.forceDark ? .dark : nil)
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
