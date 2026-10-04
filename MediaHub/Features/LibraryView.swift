import SwiftUI

struct LibraryView: View {
    @Environment(SimklStore.self) private var simkl

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(simkl.library) { CatalogRowView(row: $0) }
                }
                .padding(.vertical, 12)
            }
            .overlay {
                if !simkl.isConnected {
                    ContentUnavailableView("Connect Simkl", systemImage: "link",
                        description: Text("Sign in from Settings to see your watchlist and history."))
                } else if simkl.library.isEmpty {
                    if simkl.isSyncing { ProgressView() }
                    else { ContentUnavailableView("Nothing here yet", systemImage: "books.vertical",
                        description: Text("Titles you add on Simkl show up here.")) }
                }
            }
            .refreshable { await simkl.sync(force: true) }
            .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
            .navigationDestination(for: CatalogRow.self) { CatalogGridView(row: $0) }
            .navigationTitle("Library")
        }
    }
}
