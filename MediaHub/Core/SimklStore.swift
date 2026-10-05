import Foundation
import Observation

/// Response of `GET /oauth/pin`. `deviceCode` is parsed but not needed: polling uses the user code.
struct PinResponse: Decodable, Sendable {
    let result: String?
    let deviceCode: String?
    let userCode: String
    let verificationUrl: String
    let expiresIn: Int
    let interval: Int
}

private struct PollResponse: Decodable { let result: String?; let message: String?; let accessToken: String? }

/// Skips one malformed entry instead of failing the whole library.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from d: Decoder) throws { value = try? T(from: d) }
}
private struct AllItems: Decodable {
    let movies: [Entry]; let shows: [Entry]; let anime: [Entry]
    enum K: String, CodingKey { case movies, shows, anime }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func list(_ k: K) -> [Entry] { ((try? c.decodeIfPresent([Lossy<Entry>].self, forKey: k)) ?? []).compactMap(\.value) }
        movies = list(.movies); shows = list(.shows); anime = list(.anime)
    }
}
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

private enum SimklError: LocalizedError {
    case http(Int, String)
    case message(String)
    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Simkl answered HTTP \(code)" + (body.isEmpty ? "." : ": \(body)")
        case .message(let m): return m
        }
    }
}

private enum PollResult { case token(String), pending, failed(String), transient }

/// Simkl via the PIN / device-code flow. It needs only a client ID: no redirect URL, no client secret, no browser
/// callback, so it works inside LiveContainer where OAuth redirects can't return to the app.
///
/// Network use is event-driven: sync on foreground (max every 15 min) or pull-to-refresh, scrobble start/stop only.
@MainActor @Observable
final class SimklStore {
    private(set) var token: String? = Keychain.get("simkl.token")
    private(set) var library: [CatalogRow] = []
    private(set) var isSyncing = false
    private(set) var pin: PinResponse?
    private(set) var loginError: String?
    private(set) var loginStatus: String?
    private(set) var syncError: String?
    @ObservationIgnored private var lastSync: Date?
    @ObservationIgnored private var loginTask: Task<Void, Never>?

    var isConnected: Bool { token != nil }
    /// Trimmed: a pasted ID with a trailing space or newline is the most common reason a login "does nothing".
    private var clientID: String {
        (UserDefaults.standard.string(forKey: "simkl.clientID") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: HTTP

    private func request(_ path: String, query: [String: String] = [:], method: String = "GET",
                         body: [String: Any]? = nil, auth: Bool = true) -> URLRequest {
        var c = URLComponents(string: "https://api.simkl.com" + path)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.timeoutInterval = 20
        r.setValue(clientID, forHTTPHeaderField: "simkl-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("MediaHub/1.0", forHTTPHeaderField: "User-Agent")
        if auth, let t = token { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }

    private static func snippet(_ d: Data) -> String {
        String((String(data: d, encoding: .utf8) ?? "").prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send<T: Decodable>(_ r: URLRequest) async throws -> T {
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw SimklError.http(code, Self.snippet(d)) }
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: d)
    }

    // MARK: PIN login

    /// 1. GET /oauth/pin?client_id=…  2. show user_code + verification_url  3. poll /oauth/pin/{user_code}
    /// no faster than `interval`, while result == "KO"  4. on "OK" store access_token  5. stop at `expires_in`.
    func connect() {
        loginTask?.cancel()
        loginError = nil; loginStatus = nil; pin = nil
        let cid = clientID
        guard !cid.isEmpty else { loginError = "Enter your Simkl client ID first."; return }
        loginTask = Task { await runPinFlow(clientID: cid) }
    }

    func cancelLogin() {
        loginTask?.cancel(); pin = nil; loginStatus = nil
    }

    private func runPinFlow(clientID cid: String) async {
        do {
            loginStatus = "Requesting a code…"
            let p: PinResponse = try await send(request("/oauth/pin", query: ["client_id": cid], auth: false))
            if let r = p.result, r.uppercased() != "OK" { throw SimklError.message("Simkl refused the request (\(r)). Check your client ID.") }
            pin = p
            loginStatus = "Open the page below and enter the code."
            let deadline = Date().addingTimeInterval(Double(p.expiresIn))
            let wait = max(p.interval, 1)               // never faster than the interval Simkl asked for
            var failures = 0
            while Date() < deadline {
                try await Task.sleep(for: .seconds(wait))
                try Task.checkCancellation()
                switch await poll(code: p.userCode, clientID: cid) {
                case .token(let t):
                    token = t
                    Keychain.set(t, "simkl.token")
                    pin = nil; loginStatus = nil; loginError = nil
                    await sync(force: true)
                    return
                case .pending:
                    failures = 0
                case .failed(let m):
                    pin = nil; loginStatus = nil; loginError = m
                    return
                case .transient:
                    failures += 1
                    if failures >= 6 { pin = nil; loginStatus = nil; loginError = "Lost the connection to Simkl. Try again."; return }
                }
            }
            pin = nil; loginStatus = nil
            loginError = "The code expired. Tap Connect to get a new one."
        } catch is CancellationError {
            pin = nil; loginStatus = nil
        } catch {
            pin = nil; loginStatus = nil
            loginError = error.localizedDescription
        }
    }

    private func poll(code: String, clientID cid: String) async -> PollResult {
        let r = request("/oauth/pin/\(code)", query: ["client_id": cid], auth: false)
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return .transient }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 || status >= 500 { return .transient }
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        guard let p = try? dec.decode(PollResponse.self, from: d) else {
            return status == 200 ? .pending : .failed("Simkl answered HTTP \(status): \(Self.snippet(d))")
        }
        if let t = p.accessToken, !t.isEmpty, (p.result ?? "OK").uppercased() == "OK" { return .token(t) }
        // "KO" means not authorised yet. Only give up on messages that clearly say the code is dead.
        let m = (p.message ?? "").lowercased()
        if m.contains("expire") || m.contains("invalid") || m.contains("denied") || m.contains("not found") {
            return .failed(p.message ?? "Simkl rejected the code.")
        }
        return .pending
    }

    func disconnect() {
        loginTask?.cancel(); token = nil; pin = nil; library = []; loginStatus = nil; syncError = nil
        Keychain.remove("simkl.token")
    }

    // MARK: Library

    func sync(force: Bool = false) async {
        guard isConnected, !isSyncing else { return }
        if !force, let l = lastSync, Date().timeIntervalSince(l) < 900 { return }
        isSyncing = true; defer { isSyncing = false }
        let all: AllItems
        do { all = try await send(request("/sync/all-items/")) }
        catch {
            if case SimklError.http(let c, _) = error, c == 401 || c == 403 {
                syncError = "Simkl rejected the saved login. Disconnect and connect again."
            } else { syncError = error.localizedDescription }
            return
        }
        syncError = nil
        lastSync = .now
        let entries = all.movies + all.shows + all.anime
        func items(_ status: String) -> [MetaPreview] {
            entries.filter { $0.status == status }.compactMap { e in
                guard let m = e.movie ?? e.show,
                      let id = m.ids.imdb ?? m.ids.tmdb.map({ "tmdb:\($0)" }) else { return nil }
                return MetaPreview(id: id, type: e.movie != nil ? "movie" : "series", name: m.title,
                    poster: m.poster.map { "https://simkl.in/posters/\($0)_m.jpg" }, background: nil,
                    logo: nil, description: nil, releaseInfo: m.year.map(String.init))
            }
        }
        let sections: [(String, String, String)] = [("watching", "Watching", "eye.fill"),
                                                    ("plantowatch", "Plan to Watch", "bookmark.fill"),
                                                    ("completed", "Completed", "checkmark.circle.fill")]
        library = sections.compactMap { s, t, sym in
            let i = items(s)
            return i.isEmpty ? nil : CatalogRow(id: "simkl-\(s)", title: t, items: i, symbol: sym)
        }
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
