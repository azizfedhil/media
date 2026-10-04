import Foundation

// MARK: Stremio add-on protocol models (tolerant decoding: add-ons are inconsistent)

struct AddonManifest: Decodable, Sendable, Hashable {
    let id: String
    let name: String
    let version: String?
    let description: String?
    let logo: String?
    let types: [String]?
    let catalogs: [CatalogDef]?
    let resources: [Resource]?
    let idPrefixes: [String]?

    struct CatalogDef: Decodable, Sendable, Hashable {
        let type: String
        let id: String
        let name: String?
        let extra: [Extra]?
        struct Extra: Decodable, Sendable, Hashable {
            let name: String
            let isRequired: Bool?
        }
        /// Home rows can't satisfy required params (e.g. search-only catalogs).
        var isBrowsable: Bool { (extra ?? []).allSatisfy { !($0.isRequired ?? false) } }
    }

    /// `resources` is either ["stream"] or [{name, types, idPrefixes}].
    struct Resource: Decodable, Sendable, Hashable {
        let name: String
        let types: [String]?
        let idPrefixes: [String]?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                name = s; types = nil; idPrefixes = nil
            } else {
                struct D: Decodable { let name: String; let types: [String]?; let idPrefixes: [String]? }
                let d = try c.decode(D.self)
                name = d.name; types = d.types; idPrefixes = d.idPrefixes
            }
        }
    }
}

struct Addon: Identifiable, Sendable, Hashable {
    let manifestURL: URL
    let manifest: AddonManifest
    var id: String { manifestURL.absoluteString }
    var baseURL: URL { manifestURL.deletingLastPathComponent() }
    var homeCatalogs: [AddonManifest.CatalogDef] { (manifest.catalogs ?? []).filter(\.isBrowsable) }

    func provides(_ resource: String, type: String, id: String) -> Bool {
        guard let r = manifest.resources?.first(where: { $0.name == resource }) else { return false }
        if let t = r.types, !t.contains(type) { return false }
        if let p = (r.idPrefixes ?? manifest.idPrefixes), !p.contains(where: id.hasPrefix) { return false }
        return true
    }

    static func normalize(_ input: String) throws -> URL {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("stremio://") { s = "https://" + s.dropFirst("stremio://".count) }
        if !s.hasSuffix("manifest.json") { s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/manifest.json" }
        guard let url = URL(string: s), url.scheme?.hasPrefix("http") == true else { throw URLError(.badURL) }
        return url
    }
}

struct MetaPreview: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?

    var posterURL: URL? { poster.flatMap(URL.init(string:)) ?? metahub("poster") }
    var backdropURL: URL? {
        background.flatMap(URL.init(string:)) ?? metahub("background") ?? poster.flatMap(URL.init(string:))
    }
    private func metahub(_ kind: String) -> URL? {
        id.hasPrefix("tt") ? URL(string: "https://images.metahub.space/\(kind)/medium/\(id)/img") : nil
    }
}

struct StreamItem: Decodable, Identifiable, Sendable {
    let name: String?
    let title: String?
    let description: String?
    let url: String?        // directly playable
    let infoHash: String?   // torrent: not playable on iOS without a debrid add-on
    let externalUrl: String?
    let behaviorHints: Hints?
    var id: String { url ?? infoHash ?? externalUrl ?? UUID().uuidString }
    var isPlayable: Bool { url != nil }

    /// Optional add-on hints. Some debrid add-ons require custom request headers to fetch the file.
    struct Hints: Decodable, Sendable {
        let filename: String?
        let proxyHeaders: ProxyHeaders?
        struct ProxyHeaders: Decodable, Sendable { let request: [String: String]? }
        enum K: String, CodingKey { case filename, proxyHeaders }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            filename = try? c.decode(String.self, forKey: .filename)
            proxyHeaders = try? c.decode(ProxyHeaders.self, forKey: .proxyHeaders)
        }
    }

    var requestHeaders: [String: String] { behaviorHints?.proxyHeaders?.request ?? [:] }
    var fileExtension: String {
        let f = behaviorHints?.filename ?? URL(string: url ?? "")?.lastPathComponent ?? ""
        return URL(fileURLWithPath: f).pathExtension.lowercased()
    }
    /// AVPlayer handles MP4/MOV/HLS; these containers usually fail.
    var likelyUnsupported: Bool { ["mkv", "avi", "wmv", "flv", "webm"].contains(fileExtension) }
}

struct CatalogRow: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [MetaPreview]
}

private struct MetasResponse: Decodable { let metas: [MetaPreview] }
private struct StreamsResponse: Decodable { let streams: [StreamItem] }
extension MetaPreview { static func decodeList(_ d: Data) throws -> [MetaPreview] { try JSONDecoder().decode(MetasResponse.self, from: d).metas } }
extension StreamItem { static func decodeList(_ d: Data) throws -> [StreamItem] { try JSONDecoder().decode(StreamsResponse.self, from: d).streams } }
