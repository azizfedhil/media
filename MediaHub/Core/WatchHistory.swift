import Foundation
import Observation

/// Local progress. Powers Continue Watching, resume, and "Because you watched…" suggestions.
/// (Simkl sync will mirror this later.)
@MainActor @Observable
final class WatchHistory {
    struct Entry: Codable, Identifiable {
        let item: MetaPreview
        var key: String            // stream id incl. episode, so resume only applies to the same episode
        var position: Double
        var duration: Double
        var updated: Date
        var id: String { item.id }
    }
    private(set) var entries: [Entry] = []
    private let storeKey = "watch.history"

    init() {
        if let d = UserDefaults.standard.data(forKey: storeKey),
           let e = try? JSONDecoder().decode([Entry].self, from: d) { entries = e }
    }

    var lastWatched: MetaPreview? { entries.first?.item }
    var continueWatching: [MetaPreview] {
        entries.filter { $0.position > 30 && $0.position < $0.duration * 0.95 }.map(\.item)
    }
    func entry(for id: String) -> Entry? { entries.first { $0.id == id } }

    func update(_ item: MetaPreview, key: String, position: Double, duration: Double) {
        entries.removeAll { $0.id == item.id }
        entries.insert(Entry(item: item, key: key, position: position, duration: duration, updated: .now), at: 0)
        entries = Array(entries.prefix(30))
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: storeKey) }
    }
}
