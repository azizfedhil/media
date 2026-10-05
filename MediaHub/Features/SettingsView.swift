import SwiftUI

struct SettingsView: View {
    @Environment(AddonStore.self) private var store
    @Environment(SimklStore.self) private var simkl
    @Environment(ThemeStore.self) private var theme
    @AppStorage("tmdb.key") private var tmdbKey = ""
    @AppStorage("tvdb.key") private var tvdbKey = ""
    @AppStorage("mdblist.key") private var mdbKey = ""
    @AppStorage("ui.networkBadges") private var networkBadges = true
    @AppStorage("ui.titleLogos") private var titleLogos = true
    @AppStorage("player.glass") private var glass = true
    @AppStorage("player.autoplayNext") private var autoplayNext = true
    @AppStorage("skip.enabled") private var skipEnabled = true
    @AppStorage("skip.fallbackSeconds") private var fallbackSkip = 85
    @AppStorage("sub.lang") private var subLang = "off"
    @State private var urlText = ""
    @State private var error: String?
    @State private var busy = false

    private var connected: Int {
        [!tmdbKey.isEmpty, !tvdbKey.isEmpty, !mdbKey.isEmpty, simkl.isConnected].filter { $0 }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { IntegrationsView() } label: {
                        HStack {
                            Label("Integrations", systemImage: "puzzlepiece.extension.fill")
                            Spacer()
                            Text("\(connected) of 4 set up").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("TMDB, TheTVDB, MDBList and Simkl: API keys, logins and metadata sources.")
                }

                Section("Appearance") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Accent colour").font(.subheadline.weight(.medium))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 12)], spacing: 12) {
                            ForEach(Theme.presets, id: \.hex) { p in
                                Button { theme.setAccent(hex: p.hex) } label: {
                                    Circle().fill(Color(hex: p.hex) ?? .gray).frame(width: 36, height: 36)
                                        .overlay {
                                            if theme.hex.uppercased() == p.hex {
                                                Image(systemName: "checkmark").font(.footnote.weight(.black)).foregroundStyle(.white)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(p.name)
                            }
                        }
                        ColorPicker("Custom colour", selection: Binding(get: { theme.accent },
                                                                          set: { theme.setAccent(hex: $0.hexString) }),
                                    supportsOpacity: false)
                    }
                    .padding(.vertical, 4)
                    Toggle("Network icons on posters", isOn: $networkBadges)
                    Toggle("Logos instead of title text", isOn: $titleLogos)
                } footer: {
                    Text("Network icons need a TMDB key and make one small request per visible poster. Logos come from TMDB, TheTVDB and Metahub and are cached after the first lookup.")
                }

                Section {
                    NavigationLink {
                        SubtitleSettingsView()
                    } label: {
                        HStack {
                            Label("Subtitles", systemImage: "captions.bubble")
                            Spacer()
                            Text(subLang == "off" ? "Off" : (SubLanguages.all.first { $0.code == subLang }?.name ?? subLang))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Liquid Glass controls", isOn: $glass)
                    Toggle("Autoplay next episode", isOn: $autoplayNext)
                    Toggle("Skip intro / recap / credits", isOn: $skipEnabled)
                    if skipEnabled {
                        Stepper(fallbackSkip == 0 ? "Manual skip button: off" : "Manual skip button: \(fallbackSkip) s",
                                value: $fallbackSkip, in: 0...180, step: 5)
                    }
                } header: { Text("Playback") } footer: {
                    Text("Skip buttons use community timestamps from TheIntroDB. When a show has none, the manual button jumps ahead by the chosen time. Set it to 0 to hide it. Turn Liquid Glass off if playback ever feels heavy on an older device.")
                }

                Section("Add-ons") {
                    ForEach(store.addons) { a in
                        VStack(alignment: .leading) {
                            Text(a.manifest.name).font(.headline)
                            if let d = a.manifest.description { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                    .onDelete { store.remove(at: $0) }
                }
                Section {
                    TextField("Add-on URL", text: $urlText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button(busy ? "Adding…" : "Add add-on") {
                        Task {
                            busy = true; defer { busy = false }
                            do { try await store.add(urlText); urlText = ""; error = nil }
                            catch { self.error = "Couldn't load that manifest. Check the URL and try again." }
                        }
                    }
                    .disabled(urlText.isEmpty || busy)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Settings")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
        }
    }
}
