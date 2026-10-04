import SwiftUI

/// "See all" page for a row. Starts with the row's items, then keeps paging from the same
/// source (add-on `skip` paging or TMDB pages) as the last posters scroll into view.
struct CatalogGridView: View {
    let row: CatalogRow
    @State private var items: [MetaPreview]
    @State private var exhausted: Bool
    @State private var loading = false
    @State private var tmdbPage = 1
    @State private var offset: Int

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12, alignment: .top)]

    init(row: CatalogRow) {
        self.row = row
        _items = State(initialValue: row.items)
        _offset = State(initialValue: row.items.count)
        switch row.source {
        case .addon(_, let cat): _exhausted = State(initialValue: !cat.supportsSkip)
        case .tmdbTrending: _exhausted = State(initialValue: false)
        case nil: _exhausted = State(initialValue: true)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            PosterCard(item: item, width: nil)
                            Text(item.name).font(.caption).lineLimit(1)
                        }
                        .onAppear {
                            if item.id == items.suffix(8).first?.id { Task { await loadMore() } }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8)
                if loading { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24) }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .navigationTitle(row.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loadMore() async {
        guard !loading, !exhausted, let src = row.source else { return }
        loading = true; defer { loading = false }
        var fresh: [MetaPreview] = []
        switch src {
        case .addon(let addon, let cat):
            fresh = (try? await AddonClient.shared.catalog(addon: addon, catalog: cat, skip: offset)) ?? []
            offset += fresh.count
        case .tmdbTrending(let kind):
            fresh = (try? await TMDBClient.shared.trending(kind, page: tmdbPage + 1)) ?? []
            if !fresh.isEmpty { tmdbPage += 1 }
        }
        let known = Set(items.map(\.id))
        let new = fresh.filter { !known.contains($0.id) }
        if new.isEmpty { exhausted = true } else { items += new }
    }
}
