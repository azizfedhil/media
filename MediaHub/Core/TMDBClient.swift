import Foundation

/// Native metadata + suggestions via TMDB (free API key, entered in Settings).
/// Results are mapped to MetaPreview with id "tmdb:<id>"; the IMDb id is resolved lazily
/// when a title is opened for playback, so lists cost one request, not one per item.
actor TMDBClient {
    static let shared = TMDBClient()
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 10 << 20, diskCapacity: 50 << 20)
        return URLSession(configuration: cfg)
    }()
    private var idCache: [String: Int] = [:]
    private var networkCache: [String: NetworkBadge] = [:]
    private var networkMisses: Set<String> = []
    private var seasonCache: [String: [EpisodeInfo]] = [:]
    private var genreCache: [String: [Genre]] = [:]

    nonisolated var apiKey: String { UserDefaults.standard.string(forKey: "tmdb.key") ?? "" }
    nonisolated var hasKey: Bool { !apiKey.isEmpty }

    struct Item: Decodable { let id: Int; let title: String?; let name: String?; let overview: String?
        let posterPath: String?; let backdropPath: String?; let releaseDate: String?; let firstAirDate: String?
        let mediaType: String?; let voteAverage: Double? }
    private struct Page: Decodable { let results: [Item] }
    private struct Find: Decodable { let movieResults: [Item]; let tvResults: [Item] }
    private struct External: Decodable { let imdbId: String? }
    private struct SeasonResponse: Decodable { let episodes: [EpisodeInfo] }

    struct Genre: Decodable, Identifiable, Hashable, Sendable { let id: Int; let name: String }
    private struct GenreList: Decodable { let genres: [Genre] }
    private struct ImageSet: Decodable {
        struct Logo: Decodable { let filePath: String; let iso6391: String?; let voteAverage: Double?; let width: Int? }
        let logos: [Logo]?
    }

    private static let img = "https://image.tmdb.org/t/p/"

    /// Broadcaster / streamer icon shown on show posters.
    struct NetworkBadge: Sendable { let name: String; let logo: URL? }
    private struct TVNetworks: Decodable {
        struct Net: Decodable { let name: String; let logoPath: String? }
        let networks: [Net]?
    }

    struct SeasonInfo: Decodable, Identifiable, Sendable {
        let id: Int; let name: String?; let seasonNumber: Int
        let posterPath: String?; let episodeCount: Int?; let airDate: String?
        var posterURL: URL? { posterPath.flatMap { URL(string: TMDBClient.img + "w342" + $0) } }
        var title: String {
            if let n = name, !n.isEmpty { return n }
            return seasonNumber == 0 ? "Specials" : "Season \(seasonNumber)"
        }
    }

    struct EpisodeInfo: Decodable, Identifiable, Sendable {
        let id: Int; let name: String?; let overview: String?; let episodeNumber: Int
        let stillPath: String?; let voteAverage: Double?; let runtime: Int?; let airDate: String?
        var stillURL: URL? { stillPath.flatMap { URL(string: TMDBClient.img + "w300" + $0) } }
    }

    struct Details: Decodable, Sendable {
        let overview: String?; let tagline: String?; let runtime: Int?; let episodeRunTime: [Int]?
        let voteAverage: Double?; let genres: [Named]?
        let numberOfSeasons: Int?; let numberOfEpisodes: Int?
        let credits: Credits?; let seasons: [SeasonInfo]?
        let networks: [Named]?; let status: String?
        let productionCompanies: [Named]?; let productionCountries: [Named]?
        let spokenLanguages: [Language]?; let createdBy: [Named]?
        let firstAirDate: String?; let lastAirDate: String?; let releaseDate: String?
        let budget: Int?; let revenue: Int?

        struct Named: Decodable, Sendable { let name: String }
        struct Language: Decodable, Sendable { let englishName: String? }
        struct Credits: Decodable, Sendable { let cast: [Person]?; let crew: [Person]? }
        struct Person: Decodable, Sendable { let name: String; let job: String? }
        var minutes: Int? { runtime ?? episodeRunTime?.first }
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        guard hasKey else { throw URLError(.userAuthenticationRequired) }
        var c = URLComponents(string: "https://api.themoviedb.org/3\(path)")!
        c.queryItems = [URLQueryItem(name: "api_key", value: apiKey)] + query.map { URLQueryItem(name: $0, value: $1) }
        let (d, r) = try await session.data(from: c.url!)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: d)
    }

    private func kind(_ type: String) -> String { type == "series" ? "tv" : "movie" }

    private func preview(_ i: Item, kind: String) -> MetaPreview {
        MetaPreview(id: "tmdb:\(i.id)", type: kind == "tv" ? "series" : "movie",
            name: i.title ?? i.name ?? "Untitled",
            poster: i.posterPath.map { Self.img + "w342" + $0 }, background: i.backdropPath.map { Self.img + "w780" + $0 },
            logo: nil, description: i.overview, releaseInfo: (i.releaseDate ?? i.firstAirDate).map { String($0.prefix(4)) },
            rating: (i.voteAverage ?? 0) > 0 ? i.voteAverage : nil)
    }

    func trending(_ kind: String, page: Int = 1) async throws -> [MetaPreview] {
        let p: Page = try await get("/trending/\(kind)/week", ["page": String(page)])
        return p.results.map { preview($0, kind: kind) }
    }

    /// Movies + shows matching a free-text query.
    func search(_ query: String) async -> [MetaPreview] {
        guard hasKey, let p: Page = try? await get("/search/multi", ["query": query, "include_adult": "false"]) else { return [] }
        return p.results.compactMap { i in
            guard let t = i.mediaType, t == "movie" || t == "tv" else { return nil }
            return preview(i, kind: t)
        }
    }

    /// Network of a show (cached; shows only). One lookup per title, resolved lazily from visible posters.
    func network(for id: String, type: String) async -> NetworkBadge? {
        guard type == "series" else { return nil }
        if let hit = networkCache[id] { return hit }
        if networkMisses.contains(id) { return nil }
        guard let tid = try? await tmdbID(for: id, type: type),
              let t: TVNetworks = try? await get("/tv/\(tid)") else { return nil }
        guard let n = t.networks?.first(where: { $0.logoPath != nil }) ?? t.networks?.first else {
            networkMisses.insert(id); return nil
        }
        let badge = NetworkBadge(name: n.name, logo: n.logoPath.flatMap { URL(string: Self.img + "w92" + $0) })
        networkCache[id] = badge
        return badge
    }

    /// "More like this": TMDB recommendations, falling back to /similar when there are none.
    func recommendations(for id: String, type: String) async throws -> [MetaPreview] {
        let k = kind(type)
        let tid = try await tmdbID(for: id, type: type)
        var p: Page = try await get("/\(k)/\(tid)/recommendations")
        if p.results.isEmpty { p = try await get("/\(k)/\(tid)/similar") }
        return p.results.map { preview($0, kind: k) }
    }

    func details(for id: String, type: String) async throws -> Details {
        try await get("/\(kind(type))/\(try await tmdbID(for: id, type: type))", ["append_to_response": "credits"])
    }

    /// Episodes of one season with still image, overview and TMDB rating.
    func episodes(for id: String, type: String, season: Int) async -> [EpisodeInfo] {
        let key = "\(id):\(season)"
        if let hit = seasonCache[key] { return hit }
        guard let tid = try? await tmdbID(for: id, type: type),
              let s: SeasonResponse = try? await get("/tv/\(tid)/season/\(season)") else { return [] }
        seasonCache[key] = s.episodes
        return s.episodes
    }

    /// Numeric TMDB id for any title id we hold ("tt…" or "tmdb:…").
    func tmdbIdentifier(for id: String, type: String) async -> Int? {
        guard hasKey else { return id.hasPrefix("tmdb:") ? Int(id.dropFirst(5)) : nil }
        return try? await tmdbID(for: id, type: type)
    }

    /// Best title logo (transparent PNG): English or language-less, highest voted. SVGs are skipped (ImageIO can't draw them).
    func logo(for id: String, type: String) async -> URL? {
        guard hasKey, let tid = try? await tmdbID(for: id, type: type),
              let set: ImageSet = try? await get("/\(kind(type))/\(tid)/images", ["include_image_language": "en,null"]) else { return nil }
        let usable = (set.logos ?? []).filter { !$0.filePath.lowercased().hasSuffix(".svg") && ($0.iso6391 == "en" || $0.iso6391 == nil) }
        let best = usable.max { a, b in
            let la = a.iso6391 == "en" ? 1 : 0, lb = b.iso6391 == "en" ? 1 : 0
            if la != lb { return la < lb }
            if (a.voteAverage ?? 0) != (b.voteAverage ?? 0) { return (a.voteAverage ?? 0) < (b.voteAverage ?? 0) }
            return (a.width ?? 0) < (b.width ?? 0)
        }
        return best.flatMap { URL(string: Self.img + "w500" + $0.filePath) }
    }

    /// Genre list for Explore ("movie" | "tv"), cached.
    func genres(_ kind: String) async -> [Genre] {
        if let hit = genreCache[kind] { return hit }
        guard let g: GenreList = try? await get("/genre/\(kind)/list") else { return [] }
        genreCache[kind] = g.genres
        return g.genres
    }

    /// Filtered browsing for Explore.
    func discover(kind: String, genre: Int?, year: Int?, sort: DiscoverSort, page: Int) async throws -> [MetaPreview] {
        var q = ["page": String(page), "include_adult": "false"]
        let dateField = kind == "tv" ? "first_air_date" : "primary_release_date"
        switch sort {
        case .popular: q["sort_by"] = "popularity.desc"
        case .topRated:
            q["sort_by"] = "vote_average.desc"
            q["vote_count.gte"] = kind == "tv" ? "200" : "500"     // keeps one-vote wonders out of "top rated"
        case .newest:
            q["sort_by"] = dateField + ".desc"
            q[dateField + ".lte"] = Self.today                      // nothing unreleased
            q["vote_count.gte"] = "5"
        }
        if let genre { q["with_genres"] = String(genre) }
        if let year { q[kind == "tv" ? "first_air_date_year" : "primary_release_year"] = String(year) }
        let p: Page = try await get("/discover/\(kind)", q)
        return p.results.map { preview($0, kind: kind) }
    }

    private static var today: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: .now)
    }

    func imdbID(tmdb id: Int, type: String) async -> String? {
        let e: External? = try? await get("/\(kind(type))/\(id)/external_ids")
        return e?.imdbId
    }

    private func tmdbID(for id: String, type: String) async throws -> Int {
        if id.hasPrefix("tmdb:"), let n = Int(id.dropFirst(5)) { return n }
        if let hit = idCache[id] { return hit }
        let f: Find = try await get("/find/\(id)", ["external_source": "imdb_id"])
        guard let found = (kind(type) == "tv" ? f.tvResults : f.movieResults).first?.id else { throw URLError(.resourceUnavailable) }
        idCache[id] = found
        return found
    }
}

enum DiscoverSort: String, CaseIterable, Identifiable, Sendable {
    case popular = "Popular", topRated = "Top rated", newest = "Newest"
    var id: String { rawValue }
}
