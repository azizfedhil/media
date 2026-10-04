import SwiftUI

private struct SeasonChip: Identifiable {
    let id: Int          // season number
    let title: String
    let poster: URL?
    let count: Int?
}

struct EpisodeItem: Identifiable {
    let id: Int          // episode number
    var name: String
    var overview: String?
    var image: URL?
    var rating: Double?
    var runtime: Int?
}

struct DetailView: View {
    let item: MetaPreview
    @Environment(AddonStore.self) private var store
    @Environment(SimklStore.self) private var simkl
    @Environment(PinnedSources.self) private var pins
    @State private var imdbID: String?
    @State private var onWatchlist = false
    @State private var ratings: [MDBListClient.Rating] = []
    @State private var logoURL: URL?
    @State private var details: TMDBClient.Details?
    @State private var similar: [MetaPreview] = []
    @State private var streams: [(Addon, [StreamItem])] = []
    @State private var loadingStreams = false
    @State private var showSources = false
    @State private var playRequest: PlayRequest?
    @State private var season = 1
    @State private var episode = 1
    @State private var episodes: [EpisodeItem] = []
    @State private var loadingEpisodes = false
    @State private var seasonsExpanded = false

    private var isSeries: Bool { item.type == "series" }

    // MARK: Derived data

    private var metaLine: String {
        var parts: [String] = []
        if let y = item.releaseInfo { parts.append(y) }
        if let m = details?.minutes { parts.append("\(m) min") }
        if let g = details?.genres?.prefix(2).map(\.name), !g.isEmpty { parts.append(g.joined(separator: ", ")) }
        return parts.joined(separator: "  ")
    }

    /// TV: broadcaster/streamer. Movies: production studio.
    private var networkText: String? {
        let list = (isSeries ? details?.networks : details?.productionCompanies) ?? []
        let names = list.prefix(2).map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private var allRatings: [MDBListClient.Rating] {
        var out = ratings
        if let r = details?.voteAverage, r > 0, !out.contains(where: { $0.label == "TMDB" }) {
            out.append(MDBListClient.Rating(label: "TMDB", text: String(format: "%.1f", r), score: r))
        }
        return out
    }

    private var seasonChips: [SeasonChip] {
        if let s = details?.seasons, !s.isEmpty {
            return s.filter { ($0.episodeCount ?? 1) > 0 }
                .sorted { ($0.seasonNumber == 0 ? Int.max : $0.seasonNumber) < ($1.seasonNumber == 0 ? Int.max : $1.seasonNumber) }
                .map { SeasonChip(id: $0.seasonNumber, title: $0.title, poster: $0.posterURL, count: $0.episodeCount) }
        }
        return (1...max(details?.numberOfSeasons ?? 1, 1)).map {
            SeasonChip(id: $0, title: "Season \($0)", poster: nil, count: nil)
        }
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RemoteImage(url: item.backdropURL, size: 800)
                    .frame(height: 420)
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 140)
                    }
                header.padding(.horizontal, 20)
                if isSeries { seasonSection }
                if !similar.isEmpty {
                    CatalogRowView(row: CatalogRow(id: "similar-\(item.id)", title: "More like this", items: similar))
                        .padding(.top, 8)
                }
                detailsSection
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
        .task(id: season) { await loadEpisodes() }
        .task(id: showSources) {
            // Query stream add-ons only when the picker opens.
            guard showSources else { return }
            streams = []
            loadingStreams = true; defer { loadingStreams = false }
            guard let imdb = await stremioID() else { return }
            imdbID = imdb
            let sid = isSeries ? "\(imdb):\(season):\(episode)" : imdb
            streams = await AddonClient.shared.streams(for: sid, type: item.type, addons: store.addons)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let logoURL {
                LogoImage(url: logoURL).frame(maxWidth: 260, maxHeight: 90, alignment: .leading)
                    .accessibilityLabel(item.name)
            } else { Text(item.name).font(.largeTitle.bold()) }
            if !metaLine.isEmpty { Text(metaLine).font(.subheadline).foregroundStyle(.secondary) }
            if let n = networkText {
                Label(n, systemImage: isSeries ? "tv" : "building.2").font(.subheadline).foregroundStyle(.secondary)
            }
            if !allRatings.isEmpty { ratingsRow }
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
        }
    }

    private var ratingsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(allRatings) { RatingBadge(rating: $0) }
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Seasons + episodes

    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Seasons").font(.title3.bold())
                Spacer()
                if seasonChips.contains(where: { $0.poster != nil }) {
                    Button { withAnimation(.snappy) { seasonsExpanded.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text("Artwork")
                            Image(systemName: "chevron.down").rotationEffect(.degrees(seasonsExpanded ? 180 : 0))
                        }
                        .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal, 20)
            seasonPills
            if seasonsExpanded { seasonPosters.transition(.opacity.combined(with: .move(edge: .top))) }
            episodeCarousel
        }
    }

    private func select(season n: Int) {
        guard n != season else { return }
        withAnimation(.snappy) { season = n; episode = 1; episodes = [] }
    }

    private var seasonPills: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(seasonChips) { c in
                    Button { select(season: c.id) } label: {
                        Text(c.title).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .glassEffect(c.id == season ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                                         in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    private var seasonPosters: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(seasonChips) { c in
                    Button { select(season: c.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            RemoteImage(url: c.poster, size: 110).frame(width: 110, height: 165)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: c.id == season ? 3 : 0)
                                }
                            Text(c.title).font(.caption.weight(.medium)).lineLimit(1)
                            if let n = c.count { Text("\(n) episodes").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .frame(width: 110, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    private var episodeCarousel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    if loadingEpisodes && episodes.isEmpty {
                        ProgressView().frame(width: 280, height: 158)
                    }
                    ForEach(episodes) { episodeCard($0) }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            // No TMDB/TVDB data: keep a manual way to pick the episode.
            if episodes.isEmpty && !loadingEpisodes {
                Stepper("Episode \(episode)", value: $episode, in: 1...99).padding(.horizontal, 20)
            }
        }
    }

    private func episodeCard(_ ep: EpisodeItem) -> some View {
        let selected = ep.id == episode
        return Button { episode = ep.id; showSources = true } label: {
            RemoteImage(url: ep.image, size: 300)
                .frame(width: 280, height: 158)
                .overlay(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(ep.id). \(ep.name)").font(.subheadline.bold()).lineLimit(1)
                        if let o = ep.overview, !o.isEmpty {
                            Text(o).font(.caption).lineLimit(2).opacity(0.85)
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 10).padding(.top, 36)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                }
                .overlay(alignment: .topTrailing) {
                    if let r = ep.rating, r > 0 {
                        HStack(spacing: 4) {
                            RatingLogo(label: "TMDB", height: 11)
                            Text(String(format: "%.1f", r))
                        }
                        .font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0)
                }
        }
        .buttonStyle(.plain)
    }

    /// TMDB first (stills, overviews, ratings); TVDB fills missing thumbnails or stands in when TMDB has nothing.
    private func loadEpisodes() async {
        guard isSeries else { return }
        loadingEpisodes = true
        var list = await TMDBClient.shared.episodes(for: item.id, type: item.type, season: season).map {
            EpisodeItem(id: $0.episodeNumber, name: $0.name ?? "Episode \($0.episodeNumber)", overview: $0.overview,
                        image: $0.stillURL, rating: $0.voteAverage, runtime: $0.runtime)
        }
        let needsArt = list.contains(where: { $0.image == nil })
        if (list.isEmpty || needsArt), TVDBClient.shared.hasKey, let imdb = await ensureIMDB() {
            let tv = await TVDBClient.shared.episodes(imdb: imdb, season: season)
            if list.isEmpty {
                list = tv.compactMap { e in
                    e.number.map { EpisodeItem(id: $0, name: e.name ?? "Episode \($0)", overview: e.overview,
                                               image: e.imageURL, rating: nil, runtime: e.runtime) }
                }
            } else {
                for i in list.indices where list[i].image == nil {
                    list[i].image = tv.first(where: { $0.number == list[i].id })?.imageURL
                }
            }
        }
        guard !Task.isCancelled else { return }
        episodes = list
        loadingEpisodes = false
    }

    // MARK: Details footer

    private var detailRows: [(String, String)] {
        guard let d = details else { return [] }
        var rows: [(String, String)] = []
        func add(_ k: String, _ v: String?) { if let v, !v.isEmpty { rows.append((k, v)) } }
        func names(_ a: [TMDBClient.Details.Named]?) -> String? { a?.map(\.name).joined(separator: ", ") }
        func money(_ n: Int?) -> String? {
            guard let n, n > 0 else { return nil }
            return n.formatted(.currency(code: "USD").precision(.fractionLength(0)))
        }
        if isSeries {
            add("Network", names(d.networks))
            add("Status", d.status)
            add("First aired", prettyDate(d.firstAirDate))
            add("Last aired", prettyDate(d.lastAirDate))
            add("Seasons", d.numberOfSeasons.map(String.init))
            add("Episodes", d.numberOfEpisodes.map(String.init))
            add("Created by", names(d.createdBy))
        } else {
            add("Released", prettyDate(d.releaseDate))
            add("Director", d.credits?.crew?.filter { $0.job == "Director" }.map(\.name).joined(separator: ", "))
            add("Budget", money(d.budget))
            add("Box office", money(d.revenue))
        }
        add("Runtime", d.minutes.map { "\($0) min" })
        add("Genres", names(d.genres))
        add("Studio", names(d.productionCompanies))
        add("Country", names(d.productionCountries))
        add("Languages", d.spokenLanguages?.compactMap(\.englishName).joined(separator: ", "))
        add("Cast", d.credits?.cast?.prefix(10).map(\.name).joined(separator: ", "))
        return rows
    }

    private func prettyDate(_ s: String?) -> String? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)?.formatted(date: .long, time: .omitted)
    }

    @ViewBuilder private var detailsSection: some View {
        let rows = detailRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(isSeries ? "About the show" : "About the movie").font(.title3.bold()).padding(.bottom, 8)
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).font(.caption).foregroundStyle(.secondary)
                        Text(row.1).font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    Divider()
                }
            }
            .padding(.horizontal, 20).padding(.top, 8)
        }
    }

    // MARK: IDs

    private func ensureIMDB() async -> String? {
        if imdbID == nil { imdbID = await stremioID() }
        return imdbID
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
        playRequest = PlayRequest(url: u, headers: s.requestHeaders, item: item,
                                  key: isSeries ? "\(season):\(episode)" : "movie", imdb: imdb,
                                  season: isSeries ? season : nil, episode: isSeries ? episode : nil,
                                  episodeTitle: isSeries ? episodes.first(where: { $0.id == episode })?.name : nil,
                                  logo: logoURL)
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
