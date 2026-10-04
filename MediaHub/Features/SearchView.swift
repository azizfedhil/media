import SwiftUI

@MainActor @Observable
final class SearchModel {
    private(set) var results: [MetaPreview] = []
    private(set) var isSearching = false
    private(set) var hasSearched = false

    func reset() { results = []; isSearching = false; hasSearched = false }

    /// Add-ons that declare `search` come first (they carry IMDb ids), then TMDB fills the gaps.
    func run(_ raw: String, addons: [Addon]) async {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { reset(); return }
        isSearching = true

        var jobs: [(Addon, AddonManifest.CatalogDef)] = []
        for a in addons { for c in a.manifest.catalogs ?? [] where c.isSearchable { jobs.append((a, c)) } }
        jobs = Array(jobs.prefix(6))
        var byIndex: [Int: [MetaPreview]] = [:]
        await withTaskGroup(of: (Int, [MetaPreview]).self) { group in
            for (i, job) in jobs.enumerated() {
                group.addTask {
                    let items = (try? await AddonClient.shared.catalog(addon: job.0, catalog: job.1, search: q)) ?? []
                    return (i, items)
                }
            }
            for await (i, items) in group { byIndex[i] = items }
        }
        let tmdb = await TMDBClient.shared.search(q)
        guard !Task.isCancelled else { return }

        var out: [MetaPreview] = []
        var ids = Set<String>(), names = Set<String>()
        func add(_ m: MetaPreview) {
            guard m.type == "movie" || m.type == "series" else { return }
            let nameKey = m.name.lowercased() + "|" + (m.releaseInfo.map { String($0.prefix(4)) } ?? "")
            guard ids.insert(m.id).inserted, names.insert(nameKey).inserted else { return }
            out.append(m)
        }
        for i in jobs.indices { (byIndex[i] ?? []).forEach(add) }
        tmdb.forEach(add)
        results = out
        hasSearched = true
        isSearching = false
    }
}

struct SearchView: View {
    @Environment(AddonStore.self) private var store
    @State private var query = ""
    @State private var model = SearchModel()
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.results) { PosterCard(item: $0, width: nil) }
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    ContentUnavailableView("Search", systemImage: "magnifyingglass",
                        description: Text("Find movies and shows across your add-ons and TMDB."))
                } else if model.results.isEmpty {
                    if model.hasSearched && !model.isSearching { ContentUnavailableView.search(text: query) }
                    else { ProgressView() }
                }
            }
            .navigationTitle("Search")
            .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
            .navigationDestination(for: CatalogRow.self) { CatalogGridView(row: $0) }
        }
        .searchable(text: $query, prompt: "Movies and shows")
        .task(id: query) {
            // Debounce: only the last keystroke in a 350 ms window hits the network.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.run(query, addons: store.addons)
        }
    }
}
