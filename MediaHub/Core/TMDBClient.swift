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

    nonisolated var apiKey: String { UserDefaults.standard.string(forKey: "tmdb.key") ?? "" }
    nonisolated var hasKey: Bool { !apiKey.isEmpty }

    struct Item: Decodable { let id: Int; let title: String?; let name: String?; let overview: String?
        let posterPath: String?; let backdropPath: String?; let releaseDate: String?; let firstAirDate: String? }
    private struct Page: Decodable { let results: [Item] }
    private struct Find: Decodable { let movieResults: [Item]; let tvResults: [Item] }
    private struct External: Decodable { let imdbId: String? }
    private struct Season: Decodable { struct E: Decodable {}; let episodes: [E] }

    struct Details: Decodable, Sendable {
        let overview: String?; let tagline: String?; let runtime: Int?; let episodeRunTime: [Int]?
        let voteAverage: Double?; let genres: [Genre]?; let numberOfSeasons: Int?; let credits: Credits?
        struct Genre: Decodable, Sendable { let name: String }
        struct Credits: Decodable, Sendable { let cast: [Person] }
        struct Person: Decodable, Sendable { let name: String }
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
        let img = "https://image.tmdb.org/t/p/"
        return MetaPreview(id: "tmdb:\(i.id)", type: kind == "tv" ? "series" : "movie",
            name: i.title ?? i.name ?? "Untitled",
            poster: i.posterPath.map { img + "w342" + $0 }, background: i.backdropPath.map { img + "w780" + $0 },
            logo: nil, description: i.overview, releaseInfo: (i.releaseDate ?? i.firstAirDate).map { String($0.prefix(4)) })
    }

    func trending(_ kind: String) async throws -> [MetaPreview] {
        let p: Page = try await get("/trending/\(kind)/week")
        return p.results.map { preview($0, kind: kind) }
    }

    func recommendations(for id: String, type: String) async throws -> [MetaPreview] {
        let k = kind(type)
        let p: Page = try await get("/\(k)/\(try await tmdbID(for: id, type: type))/recommendations")
        return p.results.map { preview($0, kind: k) }
    }

    func details(for id: String, type: String) async throws -> Details {
        try await get("/\(kind(type))/\(try await tmdbID(for: id, type: type))", ["append_to_response": "credits"])
    }

    func episodeCount(for id: String, type: String, season: Int) async -> Int? {
        guard let tid = try? await tmdbID(for: id, type: type),
              let s: Season = try? await get("/tv/\(tid)/season/\(season)") else { return nil }
        return s.episodes.count
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
