import SwiftUI

/// Backs the "See all" page: starts from the row's items, then keeps loading pages as you scroll.
@MainActor @Observable
final class GridModel {
    private(set) var items: [MetaPreview]
    private(set) var isLoading = false
    private(set) var hasMore: Bool
    private let source: CatalogSource
    private var tmdbPage = 1
    private var fetched: Int      // raw count served by an add-on so far (its `skip` cursor)

    init(row: CatalogRow) {
        items = row.items
        source = row.source
        fetched = row.items.count
        switch row.source {
        case .none: hasMore = false
        case .tmdbTrending: hasMore = true
        case .addon(_, let cat): hasMore = cat.supportsSkip
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true; defer { isLoading = false }
        var fresh: [MetaPreview] = []
        switch source {
        case .none:
            break
        case .tmdbTrending(let kind):
            fresh = (try? await TMDBClient.shared.trending(kind, page: tmdbPage + 1)) ?? []
            if !fresh.isEmpty { tmdbPage += 1 }
        case .addon(let addon, let cat):
            fresh = (try? await AddonClient.shared.catalog(addon: addon, catalog: cat, skip: fetched)) ?? []
            fetched += fresh.count
        }
        let known = Set(items.map(\.id))
        let new = fresh.filter { !known.contains($0.id) }
        items += new
        // Stop when a page is empty or adds nothing new (avoids looping on add-ons that ignore `skip`).
        hasMore = !new.isEmpty
    }
}

struct CatalogGridView: View {
    let row: CatalogRow
    @State private var model: GridModel
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12)]

    init(row: CatalogRow) {
        self.row = row
        _model = State(initialValue: GridModel(row: row))
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.items) { item in
                    PosterCard(item: item, width: nil)
                        .onAppear {
                            if item.id == model.items.last?.id { Task { await model.loadMore() } }
                        }
                }
            }
            .padding(.horizontal, 16).padding(.top, 8)
            if model.isLoading { ProgressView().padding(24) }
        }
        .scrollIndicators(.hidden)
        .navigationTitle(row.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
