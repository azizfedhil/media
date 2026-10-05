import SwiftUI

/// Simkl's library when Simkl is connected, otherwise the active profile's local library.
struct LibraryView: View {
    @Environment(SimklStore.self) private var simkl
    @Environment(LocalLibrary.self) private var local
    @Environment(WatchHistory.self) private var history
    @Environment(ProfileStore.self) private var profiles

    /// Titles the profile has started and not finished (series count as long as there is progress).
    private var watching: [MetaPreview] {
        history.entries
            .filter { $0.position > 30 && ($0.item.type == "series" || !$0.isFinished) }
            .map(\.item)
    }

    private var rows: [CatalogRow] {
        simkl.isConnected ? simkl.library : local.rows(watching: watching)
    }

    private var subtitle: String {
        simkl.isConnected ? "Synced with Simkl" : "\(profiles.active.name) · On this device"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(rows) { CatalogRowView(row: $0) }
                }
                .padding(.vertical, 12)
            }
            .overlay {
                if simkl.isConnected {
                    if simkl.library.isEmpty {
                        if simkl.isSyncing { ProgressView() }
                        else { ContentUnavailableView("Nothing here yet", systemImage: "books.vertical",
                            description: Text("Titles you add on Simkl show up here.")) }
                    }
                } else if rows.isEmpty {
                    ContentUnavailableView("Your library is empty", systemImage: "books.vertical",
                        description: Text("Tap Add to Watchlist on any title to save it to \(profiles.active.name)'s library. Connect Simkl in Settings to sync across devices."))
                }
            }
            .refreshable { await simkl.sync(force: true) }
            .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
            .navigationDestination(for: CatalogRow.self) { CatalogGridView(row: $0) }
            .navigationTitle("Library")
            .navigationSubtitle(subtitle)
            .profileToolbar()
        }
    }
}
