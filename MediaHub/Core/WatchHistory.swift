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
        // Added later; optional so history saved by older builds still decodes.
        var season: Int? = nil
        var episode: Int? = nil
        var episodeTitle: String? = nil
        var thumb: String? = nil   // episode still, or the movie backdrop
        var id: String { item.id }

        var progress: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
        /// Watched far enough that the next episode is the natural thing to offer.
        var isFinished: Bool { duration > 0 && position >= duration * 0.92 }
        /// Season/episode, from the stored fields or (older entries) parsed from the "2:5" key.
        var seasonEpisode: (season: Int, episode: Int)? {
            if let s = season, let e = episode { return (s, e) }
            let p = key.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? (p[0], p[1]) : nil
        }
    }
    private(set) var entries: [Entry] = []
    private let storeKey = "watch.history"

    init() {
        if let d = UserDefaults.standard.data(forKey: storeKey),
           let e = try? JSONDecoder().decode([Entry].self, from: d) { entries = e }
    }

    var lastWatched: MetaPreview? { entries.first?.item }
    var continueEntries: [Entry] {
        entries.filter { $0.position > 30 && !$0.isFinished }
    }
    /// Shows whose last episode is done: candidates for "Up Next".
    var finishedSeries: [Entry] {
        entries.filter { $0.isFinished && $0.item.type == "series" && $0.seasonEpisode != nil }
    }
    var continueWatching: [MetaPreview] { continueEntries.map(\.item) }
    func entry(for id: String) -> Entry? { entries.first { $0.id == id } }

    func update(_ item: MetaPreview, key: String, position: Double, duration: Double,
                season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, thumb: String? = nil) {
        entries.removeAll { $0.id == item.id }
        entries.insert(Entry(item: item, key: key, position: position, duration: duration, updated: .now,
                             season: season, episode: episode, episodeTitle: episodeTitle, thumb: thumb), at: 0)
        entries = Array(entries.prefix(30))
        persist()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: storeKey) }
    }
}

/// Time formatting shared by the player and the Continue Watching cards.
enum Fmt {
    /// 83 -> "1:23", 3725 -> "1:02:05"
    static func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    /// 2460 -> "41 min left", 4500 -> "1h 15m left"
    static func remaining(_ s: Double) -> String {
        let m = max(Int((max(s, 0) / 60).rounded(.up)), 1)
        if m >= 60 { return m % 60 == 0 ? "\(m / 60)h left" : "\(m / 60)h \(m % 60)m left" }
        return "\(m) min left"
    }
}
