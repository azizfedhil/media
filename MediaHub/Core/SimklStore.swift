import Foundation
import Observation

struct PinResponse: Decodable, Sendable { let userCode: String; let verificationUrl: String; let expiresIn: Int; let interval: Int }
private struct PollResponse: Decodable { let result: String; let accessToken: String? }
private struct AllItems: Decodable { let movies: [Entry]?; let shows: [Entry]?; let anime: [Entry]? }
private struct Entry: Decodable { let status: String?; let movie: Media?; let show: Media? }
private struct Media: Decodable {
    let title: String; let year: Int?; let poster: String?; let ids: IDs
    struct IDs: Decodable {
        let imdb: String?; let tmdb: String?
        enum K: String, CodingKey { case imdb, tmdb }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            imdb = try? c.decode(String.self, forKey: .imdb)
            tmdb = (try? c.decode(String.self, forKey: .tmdb)) ?? (try? c.decode(Int.self, forKey: .tmdb)).map(String.init)
        }
    }
}

/// Simkl via PIN login (no secret needed, just a client ID). Network use is event-driven:
/// sync on foreground (max every 15 min) or pull-to-refresh, scrobble start/stop only.
@MainActor @Observable
final class SimklStore {
    private(set) var token: String? = Keychain.get("simkl.token")
    private(set) var library: [CatalogRow] = []
    private(set) var isSyncing = false
    private(set) var pin: PinResponse?
    private(set) var loginError: String?
    private var lastSync: Date?
    private var loginTask: Task<Void, Never>?

    var isConnected: Bool { token != nil }
    private var clientID: String { UserDefaults.standard.string(forKey: "simkl.clientID") ?? "" }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, auth: Bool = true) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.simkl.com" + path)!)
        r.httpMethod = method
        r.setValue(clientID, forHTTPHeaderField: "simkl-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth, let t = token { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }

    private func send<T: Decodable>(_ r: URLRequest) async throws -> T {
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: d)
    }

    // MARK: Login (poll only while the code is on screen)
    func connect() {
        loginTask?.cancel(); loginError = nil
        guard !clientID.isEmpty else { loginError = "Enter your Simkl client ID first."; return }
        loginTask = Task {
            do {
                let p: PinResponse = try await send(request("/oauth/pin?client_id=\(clientID)", auth: false))
                pin = p
                let deadline = Date().addingTimeInterval(Double(p.expiresIn))
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(max(p.interval, 5)))
                    let r: PollResponse = try await send(request("/oauth/pin/\(p.userCode)?client_id=\(clientID)", auth: false))
                    if r.result == "OK", let t = r.accessToken {
                        token = t; Keychain.set(t, "simkl.token"); pin = nil
                        await sync(force: true); return
                    }
                }
                pin = nil; loginError = "Code expired. Try again."
            } catch is CancellationError {
            } catch { pin = nil; loginError = "Couldn't reach Simkl. Check your client ID." }
        }
    }

    func disconnect() {
        loginTask?.cancel(); token = nil; pin = nil; library = []
        Keychain.remove("simkl.token")
    }

    // MARK: Library
    func sync(force: Bool = false) async {
        guard isConnected, !isSyncing else { return }
        if !force, let l = lastSync, Date().timeIntervalSince(l) < 900 { return }
        isSyncing = true; defer { isSyncing = false }
        guard let all: AllItems = try? await send(request("/sync/all-items/")) else { return }
        lastSync = .now
        let entries = (all.movies ?? []) + (all.shows ?? []) + (all.anime ?? [])
        func items(_ status: String) -> [MetaPreview] {
            entries.filter { $0.status == status }.compactMap { e in
                guard let m = e.movie ?? e.show,
                      let id = m.ids.imdb ?? m.ids.tmdb.map({ "tmdb:\($0)" }) else { return nil }
                return MetaPreview(id: id, type: e.movie != nil ? "movie" : "series", name: m.title,
                    poster: m.poster.map { "https://simkl.in/posters/\($0)_m.jpg" }, background: nil,
                    logo: nil, description: nil, releaseInfo: m.year.map(String.init))
            }
        }
        library = [("watching", "Watching"), ("plantowatch", "Plan to Watch"), ("completed", "Completed")]
            .compactMap { s, t in let i = items(s); return i.isEmpty ? nil : CatalogRow(id: "simkl-\(s)", title: t, items: i) }
    }

    func addToWatchlist(_ imdb: String, type: String) async {
        let body: [String: Any] = [type == "series" ? "shows" : "movies": [["to": "plantowatch", "ids": ["imdb": imdb]]]]
        _ = try? await URLSession.shared.data(for: request("/sync/add-to-list", method: "POST", body: body))
        await sync(force: true)
    }

    // MARK: Scrobble (start on play, stop on close; Simkl marks watched at >= 80%)
    func scrobble(_ action: String, _ r: PlayRequest, progress: Double) {
        guard isConnected else { return }
        var body: [String: Any] = ["progress": progress]
        if let s = r.season, let e = r.episode {
            body["show"] = ["ids": ["imdb": r.imdb]]; body["episode"] = ["season": s, "number": e]
        } else { body["movie"] = ["ids": ["imdb": r.imdb]] }
        let req = request("/scrobble/\(action)", method: "POST", body: body)
        Task { _ = try? await URLSession.shared.data(for: req) }
    }
}
