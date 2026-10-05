import Foundation

/// One skippable stretch of an episode or movie, in seconds.
struct SkipSegment: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case intro, recap, credits, preview }
    let kind: Kind
    let start: Double
    let end: Double?          // nil = runs to the end of the media
    var id: String { "\(kind.rawValue)-\(Int(start))" }
    var label: String {
        switch kind {
        case .intro: return "Skip Intro"
        case .recap: return "Skip Recap"
        case .credits: return "Skip Credits"
        case .preview: return "Skip Preview"
        }
    }
}

/// Intro / recap / credits / preview timestamps from TheIntroDB (community-verified, free, no API key for reads).
/// GET https://api.theintrodb.org/v3/media?tmdb_id=…&season=…&episode=…  →  { intro:[{start_ms,end_ms}], recap:[…], credits:[…], preview:[…] }
/// `null` start = beginning of the media, `null` end = end of the media.
actor IntroClient {
    static let shared = IntroClient()
    private var cache: [String: [SkipSegment]] = [:]

    nonisolated var enabled: Bool { UserDefaults.standard.object(forKey: "skip.enabled") as? Bool ?? true }

    private struct Seg: Decodable { let startMs: Double?; let endMs: Double? }
    private struct Media: Decodable { let intro: [Seg]?; let recap: [Seg]?; let credits: [Seg]?; let preview: [Seg]? }

    func segments(item: MetaPreview, imdb: String, season: Int?, episode: Int?) async -> [SkipSegment] {
        guard enabled else { return [] }
        let key = "\(item.id):\(season ?? 0):\(episode ?? 0)"
        if let hit = cache[key] { return hit }

        var q: [URLQueryItem] = []
        if let tmdb = await TMDBClient.shared.tmdbIdentifier(for: item.id, type: item.type) {
            q.append(URLQueryItem(name: "tmdb_id", value: String(tmdb)))
        } else if imdb.hasPrefix("tt") {
            q.append(URLQueryItem(name: "imdb_id", value: imdb))
        } else { return [] }
        if let s = season, let e = episode {
            q.append(URLQueryItem(name: "season", value: String(s)))
            q.append(URLQueryItem(name: "episode", value: String(e)))
        }
        var c = URLComponents(string: "https://api.theintrodb.org/v3/media")!
        c.queryItems = q
        var r = URLRequest(url: c.url!)
        r.timeoutInterval = 10
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return [] }   // offline: try again next time
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0

        var out: [SkipSegment] = []
        if status == 200 {
            let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
            if let m = try? dec.decode(Media.self, from: d) {
                func add(_ kind: SkipSegment.Kind, _ segs: [Seg]?) {
                    for s in segs ?? [] {
                        let start = max((s.startMs ?? 0) / 1000, 0)
                        let end = s.endMs.map { $0 / 1000 }
                        if let end, end - start < 3 { continue }
                        out.append(SkipSegment(kind: kind, start: start, end: end))
                    }
                }
                add(.recap, m.recap); add(.intro, m.intro); add(.credits, m.credits); add(.preview, m.preview)
                out.sort { $0.start < $1.start }
            }
        } else if status != 404 { return [] }
        cache[key] = out
        return out
    }
}
