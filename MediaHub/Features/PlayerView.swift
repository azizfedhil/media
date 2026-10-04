import SwiftUI
import AVKit

struct PlayRequest: Identifiable {
    let id = UUID()
    let url: URL
    let headers: [String: String]
    let item: MetaPreview
    let key: String
    let imdb: String
    let season: Int?
    let episode: Int?
}

/// Lets the SwiftUI layer show why AVPlayer gave up (the system UI only shows a crossed-out play icon).
@MainActor @Observable
final class PlayerState {
    var error: String?
}

/// System AVPlayerViewController: hardware decoding, PiP, AirPlay and Liquid Glass controls for free.
struct PlayerScreen: View {
    let request: PlayRequest
    @Environment(WatchHistory.self) private var history
    @Environment(SimklStore.self) private var simkl
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var state = PlayerState()

    var body: some View {
        NativePlayer(request: request, history: history, simkl: simkl, state: state)
            .ignoresSafeArea()
            .background(.black)
            .overlay { if let e = state.error { errorCard(e) } }
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).padding(6) }
                    .buttonStyle(.glass).padding(.leading, 16).padding(.top, 8)
            }
            .preferredColorScheme(.dark)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text("Couldn't play this source").font(.headline)
            Text(message).font(.footnote).multilineTextAlignment(.center).textSelection(.enabled)
            Text("The built-in player handles MP4, MOV and HLS. MKV files and some audio codecs aren't supported. Try another source, or open this one in another player.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Open in VLC") { open("vlc-x-callback://x-callback-url/stream?url=") }
                Button("Open in Infuse") { open("infuse://x-callback-url/play?url=") }
            }
            .buttonStyle(.glass)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(20)
    }

    private func open(_ prefix: String) {
        let enc = request.url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        if let u = URL(string: prefix + enc) { openURL(u) }
    }
}

struct NativePlayer: UIViewControllerRepresentable {
    let request: PlayRequest
    let history: WatchHistory
    let simkl: SimklStore
    let state: PlayerState

    func makeCoordinator() -> Coordinator { Coordinator(request: request, history: history, simkl: simkl) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        // Some add-ons (proxyHeaders) require custom headers on the media request.
        let opts: [String: Any]? = request.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": request.headers]
        let item = AVPlayerItem(asset: AVURLAsset(url: request.url, options: opts))
        let player = AVPlayer(playerItem: item)
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        context.coordinator.attach(player, state: state)
        if let e = history.entry(for: request.item.id), e.key == request.key, e.position > 30 {
            player.seek(to: CMTime(seconds: e.position, preferredTimescale: 600))
        }
        player.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.stop()
        vc.player?.pause()
        vc.player = nil
    }

    final class Coordinator {
        let request: PlayRequest
        let history: WatchHistory
        let simkl: SimklStore
        private var player: AVPlayer?
        private var token: Any?
        private var statusObs: NSKeyValueObservation?

        init(request: PlayRequest, history: WatchHistory, simkl: SimklStore) {
            self.request = request; self.history = history; self.simkl = simkl
        }

        func attach(_ p: AVPlayer, state: PlayerState) {
            player = p
            let r = request, s = simkl
            Task { @MainActor in s.scrobble("start", r, progress: 0) }
            if let item = p.currentItem {
                statusObs = item.observe(\.status, options: [.new]) { item, _ in
                    let failed = item.status == .failed
                    let ready = item.status == .readyToPlay
                    let msg = failed ? Coordinator.describe(item) : nil
                    Task { @MainActor in
                        if let msg { state.error = msg } else if ready { state.error = nil }
                    }
                }
            }
            // Coarse 10s tick: negligible wakeups, still good resume accuracy.
            token = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
                self?.save()
            }
        }

        static func describe(_ item: AVPlayerItem) -> String {
            let ns = item.error as NSError?
            var s = ns?.localizedDescription ?? "Unknown playback error"
            if let ns { s += " (\(ns.domain) \(ns.code))" }
            if let ev = item.errorLog()?.events.last, ev.errorStatusCode != 0 {
                s += "\nHTTP \(ev.errorStatusCode) \(ev.errorComment ?? "")"
            }
            return s
        }

        func save() {
            guard let p = player, let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
            let pos = p.currentTime().seconds
            MainActor.assumeIsolated { history.update(request.item, key: request.key, position: pos, duration: d) }
        }

        func stop() {
            save()
            if let p = player, let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 {
                let pct = p.currentTime().seconds / d * 100, r = request, s = simkl
                Task { @MainActor in s.scrobble("stop", r, progress: pct) }
            }
            statusObs = nil
            if let t = token { player?.removeTimeObserver(t) }
            token = nil; player = nil
        }
    }
}
