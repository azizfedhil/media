import SwiftUI

/// Navigation value for Continue Watching: opens the title with the episode you were on selected.
struct ResumeTarget: Hashable {
    let item: MetaPreview
    let season: Int?
    let episode: Int?
}

@MainActor @Observable
final class HomeModel {
    var rows: [CatalogRow] = []
    var suggested: [CatalogRow] = []
    var lists: [CatalogRow] = []

    func loadLists(selected: Set<Int>) async {
        guard MDBListClient.shared.hasKey, !selected.isEmpty else { lists = []; return }
        let chosen = await MDBListClient.shared.userLists().filter { selected.contains($0.id) }
        var done: [Int: CatalogRow] = [:]
        await withTaskGroup(of: (Int, CatalogRow?).self) { group in
            for (i, l) in chosen.enumerated() {
                group.addTask {
                    let items = await MDBListClient.shared.items(listID: l.id)
                    return (i, items.isEmpty ? nil : CatalogRow(id: "mdb-\(l.id)", title: l.name, items: items, symbol: "list.star"))
                }
            }
            for await (i, row) in group {
                guard let row else { continue }
                done[i] = row
                lists = done.keys.sorted().compactMap { done[$0] }
            }
        }
    }

    /// Trending movies and shows interleaved, so the hero mixes both.
    var hero: [MetaPreview] {
        let m = suggested.first { $0.id == "trend-movie" }?.items ?? []
        let t = suggested.first { $0.id == "trend-tv" }?.items ?? []
        var mixed: [MetaPreview] = []
        for i in 0..<max(m.count, t.count) {
            if i < m.count { mixed.append(m[i]) }
            if i < t.count { mixed.append(t[i]) }
        }
        let src = mixed.isEmpty ? (rows.first?.items ?? []) : mixed
        return Array(src.filter { $0.backdropURL != nil || $0.posterURL != nil }.prefix(7))
    }

    private nonisolated static func recommendations(after last: MetaPreview?) async -> [MetaPreview] {
        guard let l = last else { return [] }
        return (try? await TMDBClient.shared.recommendations(for: l.id, type: l.type)) ?? []
    }

    /// TMDB trending + recommendations based on the last thing you watched.
    func loadSuggestions(last: MetaPreview?) async {
        guard TMDBClient.shared.hasKey else { suggested = []; return }
        async let movies = try? await TMDBClient.shared.trending("movie")
        async let shows = try? await TMDBClient.shared.trending("tv")
        async let because = Self.recommendations(after: last)
        let (m, t, b) = await (movies, shows, because)
        var out: [CatalogRow] = []
        if let l = last, !b.isEmpty {
            out.append(CatalogRow(id: "because", title: "Because you watched \(l.name)", items: b, symbol: "sparkles"))
        }
        if let m, !m.isEmpty { out.append(CatalogRow(id: "trend-movie", title: "Trending Movies", items: m, source: .tmdbTrending("movie"), symbol: "flame.fill")) }
        if let t, !t.isEmpty { out.append(CatalogRow(id: "trend-tv", title: "Trending Shows", items: t, source: .tmdbTrending("tv"), symbol: "flame.fill")) }
        suggested = out
    }

    func load(addons: [Addon]) async {
        let jobs = addons.flatMap { a in a.homeCatalogs.map { (a, $0) } }.prefix(12)
        var done: [Int: CatalogRow] = [:]
        await withTaskGroup(of: (Int, CatalogRow?).self) { group in
            for (i, job) in jobs.enumerated() {
                group.addTask {
                    let (addon, cat) = job
                    guard let items = try? await AddonClient.shared.catalog(addon: addon, catalog: cat),
                          !items.isEmpty else { return (i, nil) }
                    let kind = cat.type == "movie" ? "Movies" : cat.type == "series" ? "Series" : cat.type.capitalized
                    return (i, CatalogRow(id: "\(addon.id)/\(cat.type)/\(cat.id)",
                                          title: "\(cat.name ?? cat.id) \(kind)", items: items,
                                          source: .addon(addon, cat), symbol: "film.stack"))
                }
            }
            // Rows appear as each catalog lands; order stays stable.
            for await (i, row) in group {
                guard let row else { continue }
                done[i] = row
                rows = done.keys.sorted().compactMap { done[$0] }
            }
        }
    }
}

extension CatalogRow {
    /// Colour of the row's title icon.
    var accent: Color {
        switch id {
        case "because": return Theme.accent2
        case "trend-movie": return .orange
        case "trend-tv": return .cyan
        default: return id.hasPrefix("mdb-") ? .teal : Theme.accent
        }
    }
}

struct HomeView: View {
    @Environment(AddonStore.self) private var store
    @Environment(WatchHistory.self) private var history
    @AppStorage("tmdb.key") private var tmdbKey = ""
    @AppStorage("mdblist.key") private var mdbKey = ""
    @AppStorage("mdblist.lists") private var mdbLists = ""
    @State private var model = HomeModel()
    /// Colour pulled from the current hero artwork; washes softly behind the first rows.
    @State private var tint: Color = Theme.accent
    private var selectedLists: Set<Int> { Set(mdbLists.split(separator: ",").compactMap { Int($0) }) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if !model.hero.isEmpty { HeroCarousel(items: model.hero, tint: $tint) }
                    if !history.continueEntries.isEmpty { ContinueRow(entries: history.continueEntries) }
                    ForEach(model.suggested) { CatalogRowView(row: $0) }
                    ForEach(model.lists) { CatalogRowView(row: $0) }
                    ForEach(model.rows) { CatalogRowView(row: $0) }
                }
                .padding(.bottom, 40)
                .animation(.smooth(duration: 0.5), value: model.rows.count + model.suggested.count + model.lists.count)
                .background(alignment: .top) { ambient }
            }
            .ignoresSafeArea(edges: .top)
            .scrollIndicators(.hidden)
            .refreshable { await refresh() }
            .overlay { if model.rows.isEmpty && model.suggested.isEmpty { ProgressView() } }
            .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
            .navigationDestination(for: ResumeTarget.self) { DetailView(item: $0.item, startSeason: $0.season, startEpisode: $0.episode) }
            .navigationDestination(for: CatalogRow.self) { CatalogGridView(row: $0) }
            .task(id: store.addons.map(\.id)) { await model.load(addons: store.addons) }
            .task(id: mdbKey + mdbLists) { await model.loadLists(selected: selectedLists) }
            .task(id: tmdbKey + (history.lastWatched?.id ?? "")) { await model.loadSuggestions(last: history.lastWatched) }
        }
    }

    private var ambient: some View {
        LinearGradient(colors: [tint.opacity(0.7), tint.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 1100)
            .allowsHitTesting(false)
    }

    private func refresh() async {
        async let a: () = model.load(addons: store.addons)
        async let b: () = model.loadSuggestions(last: history.lastWatched)
        async let c: () = model.loadLists(selected: selectedLists)
        _ = await (a, b, c)
    }
}

// MARK: - Hero

struct HeroCarousel: View {
    let items: [MetaPreview]
    @Binding var tint: Color
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var page: String?
    @State private var visible = true

    private static let interval = 7.0
    private var wide: Bool { hSize == .regular }
    private var height: CGFloat { wide ? 640 : 600 }
    private var currentID: String { page ?? items.first?.id ?? "" }
    private var index: Int { items.firstIndex(where: { $0.id == currentID }) ?? 0 }

    private struct AutoKey: Hashable { let page: String; let visible: Bool }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    HeroPage(item: item, active: item.id == currentID, wide: wide, height: height)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        .frame(height: height)
        .overlay(alignment: .bottom) {
            if items.count > 1 { HeroIndicator(count: items.count, index: index, duration: Self.interval).padding(.bottom, 12) }
        }
        .sensoryFeedback(.selection, trigger: page)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: items.map(\.id)) { _, ids in
            if let p = page, !ids.contains(p) { page = ids.first }
        }
        // Auto-advance. The task restarts on every page change (manual swipes included) and pauses off-screen.
        .task(id: AutoKey(page: currentID, visible: visible)) {
            guard visible, items.count > 1 else { return }
            try? await Task.sleep(for: .seconds(Self.interval))
            guard !Task.isCancelled else { return }
            let next = (index + 1) % items.count
            if next == 0 {
                var t = Transaction(); t.disablesAnimations = true     // rewind without streaking through every page
                withTransaction(t) { page = items[0].id }
            } else {
                withAnimation(.easeInOut(duration: 0.9)) { page = items[next].id }
            }
        }
        .task(id: currentID) { await updateTint() }
    }

    private func updateTint() async {
        guard let item = items.first(where: { $0.id == currentID }),
              let url = item.heroURL(wide: wide),
              let c = await ImagePipeline.shared.averageColor(for: url), !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.9)) { tint = Color(uiColor: c) }
    }
}

private struct HeroPage: View {
    let item: MetaPreview
    let active: Bool
    let wide: Bool
    let height: CGFloat

    var body: some View {
        NavigationLink(value: item) {
            ZStack(alignment: .bottomLeading) {
                // Slow Ken Burns zoom while this page is showing; the bottom dissolves into the ambient glow.
                RemoteImage(url: item.heroURL(wide: wide), size: wide ? 1200 : 800)
                    .scaleEffect(active ? 1.08 : 1.0)
                    .animation(active ? .linear(duration: 9) : nil, value: active)
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.6),
                                               .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .init(x: 0.5, y: 0.45), endPoint: .bottom)
                info
            }
            .frame(height: height)
            .clipped()
        }
        .buttonStyle(.plain)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(item.typeLabel.uppercased(), systemImage: item.type == "series" ? "tv" : "film")
                    .font(.caption2.weight(.heavy)).tracking(1.2)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.white.opacity(0.18), in: Capsule())
                if let y = item.year { Text(String(y)).font(.subheadline.weight(.semibold)).opacity(0.9) }
            }
            Text(item.name)
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .lineLimit(2).minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.5), radius: 10, y: 2)
            InlineRatings(item: item)
            if let d = item.description, !d.isEmpty {
                Text(d).font(.subheadline).lineLimit(2).opacity(0.85)
            }
            Label("Details", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.top, 2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.bottom, 46)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Text slides slightly faster than the artwork while paging, and fades out as it leaves.
        .scrollTransition(axis: .horizontal) { content, phase in
            content.opacity(1 - min(abs(phase.value) * 1.6, 1)).offset(x: phase.value * 70)
        }
    }
}

private struct HeroIndicator: View {
    let count: Int
    let index: Int
    let duration: Double

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                let on = i == index
                Capsule().fill(.white.opacity(0.35))
                    .frame(width: on ? 28 : 6, height: 5)
                    .overlay(alignment: .leading) { if on { AutoFill(duration: duration) } }
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: index)
            }
        }
    }
}

/// White fill that sweeps across the active indicator over one auto-advance interval.
private struct AutoFill: View {
    let duration: Double
    @State private var on = false

    var body: some View {
        Capsule().fill(.white)
            .frame(width: on ? 28 : 0, height: 5)
            .onAppear { withAnimation(.linear(duration: duration)) { on = true } }
    }
}

/// Rating pills with brand icons. Uses MDBList (IMDb / Rotten Tomatoes / Metacritic...) when a key is set,
/// and otherwise the rating that came with the title (IMDb from add-ons, TMDB from TMDB).
struct InlineRatings: View {
    let item: MetaPreview
    @State private var extra: [MDBListClient.Rating] = []

    private var chips: [MDBListClient.Rating] {
        if !extra.isEmpty {
            let order = ["IMDb", "Rotten Tomatoes", "RT Audience", "Metacritic", "Letterboxd", "Trakt"]
            return extra.sorted { (order.firstIndex(of: $0.label) ?? 99) < (order.firstIndex(of: $1.label) ?? 99) }
        }
        if let r = item.rating {
            return [MDBListClient.Rating(label: item.ratingLabel, text: String(format: "%.1f", r), score: r)]
        }
        return []
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(chips.prefix(3)) { RatingPill(rating: $0) }
        }
        .task(id: item.id) {
            extra = []
            guard MDBListClient.shared.hasKey else { return }
            var imdb: String? = item.id.hasPrefix("tt") ? item.id : nil
            if imdb == nil, item.id.hasPrefix("tmdb:"), let n = Int(item.id.dropFirst(5)), TMDBClient.shared.hasKey {
                imdb = await TMDBClient.shared.imdbID(tmdb: n, type: item.type)
            }
            guard let imdb else { return }
            extra = await MDBListClient.shared.ratings(imdb: imdb, type: item.type)
        }
    }
}

// MARK: - Continue Watching

struct ContinueRow: View {
    let entries: [WatchHistory.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent2)
                Text("Continue Watching").font(.title3.bold())
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(entries) { ContinueCard(entry: $0) }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

/// 16:9 card: episode still (or movie backdrop), where you stopped, and how much is left.
private struct ContinueCard: View {
    let entry: WatchHistory.Entry
    @Environment(WatchHistory.self) private var history
    private let width: CGFloat = 270

    private var thumb: URL? {
        entry.thumb.flatMap(URL.init(string:)) ?? entry.item.backdropURL ?? entry.item.posterURL
    }

    private var subtitle: String {
        let left = Fmt.remaining(entry.duration - entry.position)
        if let se = entry.seasonEpisode { return "S\(se.season) · E\(se.episode) · \(left)" }
        return left
    }

    var body: some View {
        NavigationLink(value: ResumeTarget(item: entry.item, season: entry.seasonEpisode?.season, episode: entry.seasonEpisode?.episode)) {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(width: width)
                    .overlay { RemoteImage(url: thumb, size: width) }
                    .overlay { LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom) }
                    .overlay {
                        Image(systemName: "play.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle())
                    }
                    .overlay(alignment: .topTrailing) {
                        Text(Fmt.clock(entry.position)).font(.system(size: 11, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.62), in: Capsule()).padding(8)
                    }
                    .overlay(alignment: .bottom) { progressBar }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button("Remove from Continue Watching", systemImage: "xmark.circle", role: .destructive) {
                withAnimation { history.remove(entry.id) }
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.3))
                Rectangle().fill(Theme.gradient).frame(width: g.size.width * entry.progress)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Rows + posters

struct CatalogRowView: View {
    let row: CatalogRow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Tapping the title opens the full list for this row.
            NavigationLink(value: row) {
                HStack(spacing: 8) {
                    if let s = row.symbol {
                        Image(systemName: s).font(.system(size: 15, weight: .bold)).foregroundStyle(row.accent)
                    }
                    Text(row.title).font(.title3.bold())
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain).padding(.horizontal, 16)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(row.items) { item in
                        PosterCard(item: item)
                            .scrollTransition(axis: .horizontal) { content, phase in
                                content.scaleEffect(phase.isIdentity ? 1 : 0.92).opacity(phase.isIdentity ? 1 : 0.6)
                            }
                    }
                    NavigationLink(value: row) {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.right.circle").font(.title)
                            Text("See all").font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(.secondary).frame(width: 100, height: 195)
                    }
                    .buttonStyle(.plain)
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

/// Springy press feedback for tappable cards.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Poster with a rating chip and an optional network icon (shows only). `width: nil` fills its grid column.
/// `showsTitle` adds the title and year underneath (grids and search).
struct PosterCard: View {
    let item: MetaPreview
    var width: CGFloat? = 130
    var showsTitle = false
    @AppStorage("ui.networkBadges") private var showNetwork = true
    @State private var network: TMDBClient.NetworkBadge?

    private var caption: String {
        [item.year.map(String.init), item.typeLabel].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 7) {
                poster
                if showsTitle {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.footnote.weight(.semibold))
                            .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                        Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: width, alignment: .topLeading)
        }
        .buttonStyle(PressableStyle())
        // Visible cards only (LazyHStack/LazyVGrid); cancelled when scrolled away, cached afterwards.
        .task(id: item.id) {
            network = nil
            guard showNetwork, item.type == "series", TMDBClient.shared.hasKey else { return }
            network = await TMDBClient.shared.network(for: item.id, type: item.type)
        }
    }

    private var poster: some View {
        RemoteImage(url: item.posterURL, size: (width ?? 120) * 1.5)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                if let logo = network?.logo {
                    LogoImage(url: logo)
                        .frame(maxWidth: 34, maxHeight: 14)
                        .padding(.horizontal, 6).padding(.vertical, 5)
                        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(6)
                        .accessibilityLabel(network?.name ?? "")
                }
            }
            .overlay(alignment: .bottomLeading) { RatingChip(item: item).padding(6) }
    }
}
