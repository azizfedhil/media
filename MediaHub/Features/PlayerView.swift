import SwiftUI
import Combine
import AetherEngine

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

/// Thin wrapper over AetherEngine (FFmpeg demux + VideoToolbox hardware decode): plays MKV, AVI, WebM and
/// DTS / TrueHD / Opus audio, while the heavy lifting stays in Apple's hardware decoder.
@MainActor @Observable
final class PlayerModel {
    var isPlaying = false
    var isBuffering = true
    var position: Double = 0
    var duration: Double = 0
    var error: String?
    var scrubbing = false

    let engine: AetherEngine?
    @ObservationIgnored private var bag = Set<AnyCancellable>()

    init() {
        do { engine = try AetherEngine() }
        catch { engine = nil; self.error = "Couldn't start the player engine: \(error.localizedDescription)" }
    }

    func start(_ r: PlayRequest, resume: Double?) async {
        guard let engine else { return }
        bind(engine)
        error = nil; isBuffering = true
        do {
            try await engine.load(url: r.url, options: LoadOptions(httpHeaders: r.headers))
            engine.play()
            if let resume, resume > 30 { await engine.seek(to: resume) }
        } catch {
            self.error = error.localizedDescription
            isBuffering = false
        }
    }

    private func bind(_ engine: AetherEngine) {
        guard bag.isEmpty else { return }
        engine.$state.receive(on: DispatchQueue.main).sink { [weak self] s in
            guard let self else { return }
            switch s {
            case .playing: isPlaying = true; isBuffering = false; error = nil
            case .paused: isPlaying = false; isBuffering = false
            case .loading, .seeking: isBuffering = true
            case .ended: isPlaying = false; isBuffering = false
            case .error: isPlaying = false; isBuffering = false; error = "Playback failed (\(String(describing: s)))."
            default: break
            }
        }.store(in: &bag)
        engine.$duration.receive(on: DispatchQueue.main).sink { [weak self] d in self?.duration = Double(d) }.store(in: &bag)
        engine.clock.$currentTime.receive(on: DispatchQueue.main).sink { [weak self] t in
            guard let self, !scrubbing else { return }
            position = Double(t)
        }.store(in: &bag)
    }

    func togglePlay() { engine?.togglePlayPause() }

    func seek(to t: Double) async {
        let target = min(max(t, 0), duration > 0 ? duration : t)
        position = target
        await engine?.seek(to: target)
    }

    func shutdown() {
        bag.removeAll()
        engine?.stop()
    }
}

/// Fullscreen player with Liquid Glass controls drawn on top of the engine's video surface.
struct PlayerScreen: View {
    let request: PlayRequest
    @Environment(WatchHistory.self) private var history
    @Environment(SimklStore.self) private var simkl
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var model = PlayerModel()
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubValue: Double = 0
    @State private var scrobbled = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine = model.engine { AetherPlayerSurface(engine: engine).ignoresSafeArea() }
            Color.clear.contentShape(Rectangle()).onTapGesture { toggleControls() }
            if model.isBuffering && model.error == nil { ProgressView().controlSize(.large).tint(.white) }
            if showControls || model.error != nil { controls.transition(.opacity) }
            if let e = model.error { errorCard(e) }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!showControls)
        .task { await begin() }
        .task {
            // Coarse 10 s tick: negligible wakeups, still good resume accuracy.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                save()
            }
        }
        .onChange(of: model.position) { _, p in if !model.scrubbing { scrubValue = p } }
        .onChange(of: model.isPlaying) { _, playing in
            if playing && !scrobbled { scrobbled = true; simkl.scrobble("start", request, progress: 0) }
            if playing { scheduleHide() } else { hideTask?.cancel() }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; finish() }
    }

    // MARK: Controls

    private var controls: some View {
        VStack {
            HStack {
                glassButton("xmark", size: 44) { dismiss() }
                Spacer()
            }
            Spacer()
            HStack(spacing: 28) {
                glassButton("gobackward.10", size: 56) { skip(-10) }
                glassButton(model.isPlaying ? "pause.fill" : "play.fill", size: 76) { model.togglePlay(); scheduleHide() }
                glassButton("goforward.10", size: 56) { skip(10) }
            }
            Spacer()
            VStack(spacing: 4) {
                Slider(value: $scrubValue, in: 0...max(model.duration, 1), onEditingChanged: { editing in
                    model.scrubbing = editing
                    if editing { hideTask?.cancel() }
                    else { Task { await model.seek(to: scrubValue); scheduleHide() } }
                })
                HStack {
                    Text(time(scrubValue)); Spacer(); Text("-" + time(max(model.duration - scrubValue, 0)))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .foregroundStyle(.white)
    }

    private func glassButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text("Couldn't play this source").font(.headline)
            Text(message).font(.footnote).multilineTextAlignment(.center).textSelection(.enabled)
            Text("The link may have expired or the server may be refusing the request. Try another source, or open this one in another player.")
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

    // MARK: Actions

    private func begin() async {
        var resume: Double?
        if let e = history.entry(for: request.item.id), e.key == request.key, e.position > 30 { resume = e.position }
        await model.start(request, resume: resume)
        scheduleHide()
    }

    private func skip(_ delta: Double) {
        Task { await model.seek(to: model.position + delta); scheduleHide() }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard model.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !model.scrubbing else { return }
            withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
        }
    }

    private func save() {
        guard model.duration > 0, model.position > 0 else { return }
        history.update(request.item, key: request.key, position: model.position, duration: model.duration)
    }

    private func finish() {
        hideTask?.cancel()
        save()
        if model.duration > 0 {
            simkl.scrobble("stop", request, progress: model.position / model.duration * 100)
        }
        model.shutdown()
    }

    private func open(_ prefix: String) {
        let enc = request.url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        if let u = URL(string: prefix + enc) { openURL(u) }
    }

    private func time(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
