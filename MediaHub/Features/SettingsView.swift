import SwiftUI

struct SettingsView: View {
    @Environment(AddonStore.self) private var store
    @Environment(SimklStore.self) private var simkl
    @AppStorage("simkl.clientID") private var simklID = ""
    @AppStorage("mdblist.key") private var mdbKey = ""
    @AppStorage("tvdb.key") private var tvdbKey = ""
    @AppStorage("tvdb.pin") private var tvdbPin = ""
    @AppStorage("tmdb.key") private var tmdbKey = ""
    @State private var urlText = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("TMDB API key", text: $tmdbKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Metadata & suggestions") } footer: {
                    Text("Free key at themoviedb.org/settings/api. This product uses the TMDB API but is not endorsed or certified by TMDB.")
                }
                Section {
                    SecureField("TVDB API key", text: $tvdbKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("PIN (subscriber keys only)", text: $tvdbPin)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("TheTVDB") } footer: {
                    Text("Adds episode thumbnails and title logos. Metadata provided by TheTVDB. Get a key at thetvdb.com/api-information.")
                }
                Section {
                    SecureField("MDBList API key", text: $mdbKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !mdbKey.isEmpty { NavigationLink("Choose lists") { MDBListPicker() } }
                } header: { Text("MDBList") } footer: {
                    Text("Adds IMDb, Rotten Tomatoes, Metacritic and Letterboxd ratings, and your lists on Home. Get a key at mdblist.com/preferences.")
                }
                Section {
                    if simkl.isConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                        Button("Sync now") { Task { await simkl.sync(force: true) } }
                        Button("Disconnect", role: .destructive) { simkl.disconnect() }
                    } else {
                        TextField("Simkl client ID", text: $simklID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if let pin = simkl.pin {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(pin.userCode).font(.largeTitle.monospaced().bold()).textSelection(.enabled)
                                if let u = URL(string: pin.verificationUrl) { Link("Enter this code at \(pin.verificationUrl)", destination: u) }
                                ProgressView()
                            }
                        } else { Button("Connect Simkl") { simkl.connect() } }
                        if let e = simkl.loginError { Text(e).foregroundStyle(.red) }
                    }
                } header: { Text("Simkl") } footer: {
                    Text("Create a free app at simkl.com/settings/developer to get a client ID.")
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
        }
    }
}
