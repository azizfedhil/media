import SwiftUI

struct DetailView: View {
    let item: MetaPreview
    @Environment(AddonStore.self) private var store
    @Environment(SimklStore.self) private var simkl
    @Environment(PinnedSources.self) private var pins
    @State private var imdbID: String?
    @State private var onWatchlist = false
    @State private var ratings: [MDBListClient.Rating] = []
    @State private var episodes: [TVDBClient.Episode] = []
    @State private var logoURL: URL?
    @State private var details: TMDBClient.Details?
    @State private var similar: [MetaPreview] = []
    @State private var streams: [(Addon, [StreamItem])] = []
    @State private var loadingStreams = false
    @State private var showSources = false
    @State private var playRequest: PlayRequest?
    @State private var season = 1
    @State private var episode = 1
    @State private var episodeCount: Int?

    private var isSeries: Bool { item.type == "series" }

    private var metaLine: String {
        var parts: [String] = []
        if let y = item.releaseInfo { parts.append(y) }
        if let m = details?.minutes { parts.append("\(m) min") }
        if let r = details?.voteAverage, r > 0 { parts.append("★ " + String(format: "%.1f", r)) }
        if let g = details?.genres?.prefix(2).map(\.name), !g.isEmpty { parts.append(g.joined(separator: ", ")) }
        return parts.joined(separator: "  ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RemoteImage(url: item.backdropURL, size: 800)
                    .frame(height: 420)
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 140)
                    }
                VStack(alignment: .leading, spacing: 12) {
                    if let logoURL {
                        LogoImage(url: logoURL).frame(maxWidth: 260, maxHeight: 90, alignment: .leading)
                            .accessibilityLabel(item.name)
                    } else { Text(item.name).font(.largeTitle.bold()) }
                    if !metaLine.isEmpty { Text(metaLine).font(.subheadline).foregroundStyle(.secondary) }
                    if !ratings.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(ratings) { r in
                                    HStack(spacing: 4) { Text(r.label).foregroundStyle(.secondary); Text(r.text).bold() }
                                        .font(.footnote).padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                    if isSeries {
                        GlassEffectContainer {
                            HStack {
                                Stepper("Season \(season)", value: $season, in: 1...max(details?.numberOfSeasons ?? 20, 1))
                                Stepper("Episode \(episode)", value: $episode, in: 1...max(episodeCount ?? 50, 1))
                            }
                            .padding(12).glassEffect(in: .rect(cornerRadius: 16))
                        }
                    }
                    Button { showSources = true } label: {
                        Label(isSeries ? "Play S\(season):E\(episode)" : "Play", systemImage: "play.fill")
                            .font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    if simkl.isConnected {
                        Button {
                            Task {
                                if let imdb = await stremioID() { await simkl.addToWatchlist(imdb, type: item.type); onWatchlist = true }
                            }
                        } label: {
                            Label(onWatchlist ? "On your watchlist" : "Add to Watchlist", systemImage: onWatchlist ? "checkmark" : "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass).disabled(onWatchlist)
                    }
                    if let t = details?.tagline, !t.isEmpty { Text(t).italic().foregroundStyle(.secondary) }
                    if let d = details?.overview ?? item.description { Text(d) }
                    if let cast = details?.credits?.cast.prefix(6).map(\.name), !cast.isEmpty {
                        Text("Starring " + cast.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                if !episodes.isEmpty { episodeList }
                if !similar.isEmpty {
                    CatalogRowView(row: CatalogRow(id: "similar-\(item.id)", title: "More like this", items: similar))
                        .padding(.top, 8)
                }
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .toolbarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSources) { sourceSheet }
        .task {
            // Native metadata + suggestions (no-ops without a TMDB key).
            async let d = try? TMDBClient.shared.details(for: item.id, type: item.type)
            async let s = try? TMDBClient.shared.recommendations(for: item.id, type: item.type)
            details = await d
            similar = await s ?? []
        }
        .task {
            guard MDBListClient.shared.hasKey, let imdb = await stremioID() else { return }
            imdbID = imdb
            ratings = await MDBListClient.shared.ratings(imdb: imdb, type: item.type)
        }
        .task {
            guard TVDBClient.shared.hasKey, let imdb = await ensureIMDB() else { return }
            logoURL = await TVDBClient.shared.logo(imdb: imdb, type: item.type)
        }
        .task(id: season) {
            guard isSeries, TVDBClient.shared.hasKey, let imdb = await ensureIMDB() else { episodes = []; return }
            episodes = await TVDBClient.shared.episodes(imdb: imdb, season: season)
        }
        .task(id: season) {
            episode = 1
            if isSeries { episodeCount = await TMDBClient.shared.episodeCount(for: item.id, type: item.type, season: season) }
        }
        .task(id: showSources) {
            // Query stream add-ons only when the picker opens.
            guard showSources else { return }
            loadingStreams = true; defer { loadingStreams = false }
            guard let imdb = await stremioID() else { streams = []; return }
            imdbID = imdb
            let sid = isSeries ? "\(imdb):\(season):\(episode)" : imdb
            streams = await AddonClient.shared.streams(for: sid, type: item.type, addons: store.addons)
        }
    }

    private func ensureIMDB() async -> String? {
        if imdbID == nil { imdbID = await stremioID() }
        return imdbID
    }

    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Season \(season)").font(.title3.bold())
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(episodes) { ep in
                    Button { episode = ep.number ?? 1; showSources = true } label: {
                        HStack(alignment: .top, spacing: 12) {
                            RemoteImage(url: ep.imageURL, size: 160).frame(width: 128, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(ep.number ?? 0). \(ep.name ?? "Episode")").font(.subheadline.bold()).lineLimit(1)
                                if let o = ep.overview, !o.isEmpty { Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                if let r = ep.runtime { Text("\(r) min").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    private func stremioID() async -> String? {
        if item.id.hasPrefix("tmdb:"), let n = Int(item.id.dropFirst(5)) {
            return await TMDBClient.shared.imdbID(tmdb: n, type: item.type)
        }
        return item.id
    }

    // MARK: Sources + pinning

    /// The pinned stream for this show: exact add-on + name match, else that add-on's first playable stream.
    private var pinned: (addon: Addon, stream: StreamItem)? {
        guard let imdb = imdbID, let pin = pins.pin(for: imdb),
              let group = streams.first(where: { $0.0.id == pin.addonID }) else { return nil }
        let playable = group.1.filter(\.isPlayable)
        guard let s = playable.first(where: { $0.signature == pin.signature }) ?? playable.first else { return nil }
        return (group.0, s)
    }

    private func play(_ s: StreamItem) {
        guard let u = s.url.flatMap(URL.init(string:)), let imdb = imdbID else { return }
        playRequest = PlayRequest(url: u, item: item, key: isSeries ? "\(season):\(episode)" : "movie", imdb: imdb,
                                  season: isSeries ? season : nil, episode: isSeries ? episode : nil)
    }

    private func row(_ addon: Addon, _ s: StreamItem, isPinned: Bool) -> some View {
        Button { play(s) } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(s.name ?? s.title ?? "Stream").font(.headline)
                    if let t = s.description ?? s.title { Text(t).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if isPinned { Image(systemName: "pin.fill").foregroundStyle(.tint) }
            }
        }
        .disabled(!s.isPlayable)
        .swipeActions {
            if let imdb = imdbID {
                if isPinned { Button("Unpin", systemImage: "pin.slash") { pins.remove(for: imdb) }.tint(.gray) }
                else if s.isPlayable {
                    Button("Pin", systemImage: "pin") { pins.set(Pin(addonID: addon.id, signature: s.signature), for: imdb) }.tint(.orange)
                }
            }
        }
    }

    private var sourceSheet: some View {
        NavigationStack {
            List {
                if let p = pinned {
                    Section("Pinned · \(p.addon.manifest.name)") { row(p.addon, p.stream, isPinned: true) }
                }
                ForEach(streams, id: \.0.id) { addon, items in
                    Section {
                        ForEach(items.filter { $0.id != pinned?.stream.id }) { row(addon, $0, isPinned: false) }
                    } header: { Text(addon.manifest.name) } footer: {
                        if addon.id == streams.first?.0.id { Text("Swipe a source to pin it to the top for this show.") }
                    }
                }
            }
            .overlay {
                if loadingStreams { ProgressView() }
                else if streams.isEmpty {
                    ContentUnavailableView("No sources", systemImage: "play.slash",
                        description: Text("Add a stream add-on in Settings."))
                }
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $playRequest) { PlayerScreen(request: $0) }
        }
        .presentationDetents([.medium, .large])
    }
}
