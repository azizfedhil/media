import SwiftUI
import UIKit

/// Static look-and-feel constants. The accent colour itself is user-chosen: see `ThemeStore`.
enum Theme {
    static let defaultHex = "#7D5CFF"      // electric violet
    static let presets: [(name: String, hex: String)] = [
        ("Violet", "#7D5CFF"), ("Pink", "#FF5C8D"), ("Blue", "#2F80FF"), ("Cyan", "#14B8D4"),
        ("Green", "#22C55E"), ("Gold", "#F5B301"), ("Orange", "#FF8A1F"), ("Red", "#EF4444"),
    ]
    /// Colourful glows and hero art read best on black. Set to false to follow the system appearance.
    static let forceDark = true
}

/// The user's accent colour. Views read it from the environment, so changing it in Settings updates the whole app live.
@MainActor @Observable
final class ThemeStore {
    private(set) var hex: String

    init() { hex = UserDefaults.standard.string(forKey: "ui.accent") ?? Theme.defaultHex }

    func setAccent(hex: String) {
        self.hex = hex
        UserDefaults.standard.set(hex, forKey: "ui.accent")
    }

    var accent: Color { Color(hex: hex) ?? Color(hex: Theme.defaultHex) ?? .purple }
    /// A neighbouring hue, for gradients (progress bars, glows).
    var accent2: Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(accent).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double((h + 0.1).truncatingRemainder(dividingBy: 1)), saturation: Double(min(s, 0.9)), brightness: Double(min(b + 0.1, 1)))
    }
    var gradient: LinearGradient { LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing) }
}

extension Color {
    /// "#RRGGBB" or "RRGGBB".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

@main
struct MediaHubApp: App {
    @State private var store = AddonStore()
    @State private var history = WatchHistory()
    @State private var simkl = SimklStore()
    @State private var pins = PinnedSources()
    @State private var theme = ThemeStore()
    @State private var profiles = ProfileStore()
    @State private var library = LocalLibrary()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store).environment(history).environment(simkl).environment(pins).environment(theme)
                .environment(profiles).environment(library)
                .preferredColorScheme(Theme.forceDark ? .dark : nil)
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var phase
    @Environment(SimklStore.self) private var simkl
    @Environment(ThemeStore.self) private var theme
    @Environment(ProfileStore.self) private var profiles
    @Environment(WatchHistory.self) private var history
    @Environment(LocalLibrary.self) private var library

    var body: some View {
        // System TabView gives Liquid Glass tab bar for free.
        TabView {
            Tab("Home", systemImage: "house.fill") { HomeView() }
            Tab("Explore", systemImage: "safari.fill") { ExploreView() }
            Tab("Library", systemImage: "books.vertical.fill") { LibraryView() }
            Tab("Settings", systemImage: "gearshape.fill") { SettingsView() }
            Tab(role: .search) { SearchView() }
        }
        .tint(theme.accent)
        .tabBarMinimizeBehavior(.onScrollDown)
        // Each profile has its own watch history and local library; swap them when the profile changes.
        .onChange(of: profiles.activeID, initial: true) { _, id in
            history.load(profile: id)
            library.load(profile: id)
        }
        .sensoryFeedback(.selection, trigger: profiles.activeID)
        .task { await simkl.sync() }
        .onChange(of: phase) { _, p in if p == .active { Task { await simkl.sync() } } }
    }
}
