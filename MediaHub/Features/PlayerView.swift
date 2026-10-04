import SwiftUI
import AVKit

struct PlayRequest: Identifiable {
    let id = UUID()
    let url: URL
    let item: MetaPreview
    let key: String
    let imdb: String
    let season: Int?
    let episode: Int?
}

/// System AVPlayerViewController: hardware decoding, PiP, AirPlay and Liquid Glass controls for free.
struct PlayerScreen: View {
    let request: PlayRequest
    @Environment(WatchHistory.self) private var history
    @Environment(SimklStore.self) private var simkl
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NativePlayer(request: request, history: history, simkl: simkl)
            .ignoresSafeArea()
            .background(.black)
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).padding(6) }
                    .buttonStyle(.glass).padding(.leading, 16).padding(.top, 8)
            }
    }
}

struct NativePlayer: UIViewControllerRepresentable {
    let request: PlayRequest
    let history: WatchHistory
    let simkl: SimklStore

    func makeCoordinator() -> Coordinator { Coordinator(request: request, history: history, simkl: simkl) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let player = AVPlayer(url: request.url)
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        context.coordinator.attach(player)
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

        init(request: PlayRequest, history: WatchHistory, simkl: SimklStore) {
            self.request = request; self.history = history; self.simkl = simkl
        }

        func attach(_ p: AVPlayer) {
            player = p
            let r = request, s = simkl
            Task { @MainActor in s.scrobble("start", r, progress: 0) }
            // Coarse 10s tick: negligible wakeups, still good resume accuracy.
            token = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
                self?.save()
            }
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
            if let t = token { player?.removeTimeObserver(t) }
            token = nil; player = nil
        }
    }
}
