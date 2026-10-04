import SwiftUI

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
                    return (i, items.isEmpty ? nil : CatalogRow(id: "mdb-\(l.id)", title: l.name, items: items))
                }
            }
            for await (i, row) in group {
                guard let row else { continue }
                done[i] = row
                lists = done.keys.sorted().compactMap { done[$0] }
            }
        }
    }
    var hero: [MetaPreview] {
        let src = suggested.first { $0.id == "trend-movie" }?.items ?? rows.first?.items ?? []
        return src.filter { $0.backdropURL != nil }.prefix(6).map { $0 }
    }

    /// TMDB trending + recommendations based on the last thing you watched.
    func loadSuggestions(last: MetaPreview?) async {
        guard TMDBClient.shared.hasKey else { suggested = []; return }
        async let movies: [MetaPreview]? = try? TMDBClient.shared.trending("movie")
        async let shows: [MetaPreview]? = try? TMDBClient.shared.trending("tv")
        async let because: [MetaPreview]? = {
            guard let l = last else { return nil }
            return try? await TMDBClient.shared.recommendations(for: l.id, type: l.type)
        }()
        var out: [CatalogRow] = []
        if let l = last, let b = await because, !b.isEmpty {
            out.append(CatalogRow(id: "because", title: "Because you watched \(l.name)", items: b))
        }
        if let m = await movies, !m.isEmpty { out.append(CatalogRow(id: "trend-movie", title: "Trending Movies", items: m)) }
        if let t = await shows, !t.isEmpty { out.append(CatalogRow(id: "trend-tv", title: "Trending Shows", items: t)) }
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
                                          title: "\(cat.name ?? cat.id) \(kind)", items: items))
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

struct HomeView: View {
    @Environment(AddonStore.self) private var store
    @Environment(WatchHistory.self) private var history
    @AppStorage("tmdb.key") private var tmdbKey = ""
    @AppStorage("mdblist.key") private var mdbKey = ""
    @AppStorage("mdblist.lists") private var mdbLists = ""
    @State private var model = HomeModel()
    private var selectedLists: Set<Int> { Set(mdbLists.split(separator: ",").compactMap { Int($0) }) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if !model.hero.isEmpty { HeroCarousel(items: model.hero) }
                    if !history.continueWatching.isEmpty {
                        CatalogRowView(row: CatalogRow(id: "continue", title: "Continue Watching", items: history.continueWatching))
                    }
                    ForEach(model.suggested) { CatalogRowView(row: $0) }
                    ForEach(model.lists) { CatalogRowView(row: $0) }
                    ForEach(model.rows) { CatalogRowView(row: $0) }
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .scrollIndicators(.hidden)
            .overlay { if model.rows.isEmpty && model.suggested.isEmpty { ProgressView() } }
            .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
            .task(id: store.addons.map(\.id)) { await model.load(addons: store.addons) }
            .task(id: mdbKey + mdbLists) { await model.loadLists(selected: selectedLists) }
            .task(id: tmdbKey + (history.lastWatched?.id ?? "")) { await model.loadSuggestions(last: history.lastWatched) }
        }
    }
}

struct HeroCarousel: View {
    let items: [MetaPreview]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        ZStack(alignment: .bottomLeading) {
                            RemoteImage(url: item.posterURL ?? item.backdropURL, size: 800)
                            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.name).font(.largeTitle.bold()).lineLimit(2)
                                if let info = item.releaseInfo { Text(info).font(.subheadline).opacity(0.8) }
                                Label("Details", systemImage: "play.fill")
                                    .font(.headline).padding(.horizontal, 20).padding(.vertical, 12)
                                    .glassEffect(.regular.interactive(), in: .capsule)
                            }
                            .foregroundStyle(.white).padding(20).padding(.bottom, 8)
                        }
                        .containerRelativeFrame(.horizontal)
                        .frame(height: 560)
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
    }
}

struct CatalogRowView: View {
    let row: CatalogRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title).font(.title3.bold()).padding(.horizontal, 16)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(row.items) { PosterCard(item: $0) }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

struct PosterCard: View {
    let item: MetaPreview

    var body: some View {
        NavigationLink(value: item) {
            RemoteImage(url: item.posterURL, size: 130)
                .frame(width: 130, height: 195)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
