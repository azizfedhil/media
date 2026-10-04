import Foundation
import Observation

@MainActor @Observable
final class AddonStore {
    private(set) var addons: [Addon] = []
    private let key = "addon.manifestURLs"
    // Public metadata-only add-on, so Home isn't empty on first launch.
    private static let defaults = ["https://v3-cinemeta.strem.io/manifest.json"]

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? Self.defaults
        Task { await restore(saved) }
    }

    func add(_ input: String) async throws {
        let url = try Addon.normalize(input)
        guard !addons.contains(where: { $0.manifestURL == url }) else { return }
        let manifest = try await AddonClient.shared.manifest(at: url)
        addons.append(Addon(manifestURL: url, manifest: manifest))
        persist()
    }

    func remove(at offsets: IndexSet) {
        addons.remove(atOffsets: offsets)
        persist()
    }

    // TODO: move to Keychain — debrid add-on URLs embed API keys.
    private func persist() {
        UserDefaults.standard.set(addons.map(\.manifestURL.absoluteString), forKey: key)
    }

    private func restore(_ urls: [String]) async {
        var found: [Int: Addon] = [:]
        await withTaskGroup(of: (Int, Addon?).self) { group in
            for (i, s) in urls.enumerated() {
                group.addTask {
                    guard let url = try? Addon.normalize(s),
                          let m = try? await AddonClient.shared.manifest(at: url) else { return (i, nil) }
                    return (i, Addon(manifestURL: url, manifest: m))
                }
            }
            for await (i, a) in group { found[i] = a }
        }
        addons = found.keys.sorted().compactMap { found[$0] }
    }
}
