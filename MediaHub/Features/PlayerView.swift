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
    var episodeTitle: String? = nil
    var logo: URL? = nil
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
    var isPaused = false
    var audioTracks: [TrackInfo] = []
    var subtitleTracks: [TrackInfo] = []
    var activeAudioID: Int?
    var activeSubtitleID: Int?
    var activeCues: [SubCue] = []

    let engine: AetherEngine?
    @ObservationIgnored private var bag = Set<AnyCancellable>()
    @ObservationIgnored private var allCues: [SubCue] = []
    @ObservationIgnored private var sourceTime: Double = 0

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
            case .playing: isPlaying = true; isPaused = false; isBuffering = false; error = nil; refreshTracks()
            case .paused: isPlaying = false; isPaused = true; isBuffering = false
            case .loading, .seeking: isBuffering = true; isPaused = false
            case .ended: isPlaying = false; isPaused = false; isBuffering = false
            case .error: isPlaying = false; isPaused = false; isBuffering = false; error = "Playback failed (\(String(describing: s)))."
            default: break
            }
        }.store(in: &bag)
        engine.$duration.receive(on: DispatchQueue.main).sink { [weak self] d in self?.duration = Double(d) }.store(in: &bag)
        engine.clock.$currentTime.receive(on: DispatchQueue.main).sink { [weak self] t in
            guard let self, !scrubbing else { return }
            position = Double(t)
        }.store(in: &bag)
        // Subtitle cues arrive as one cumulative list in source time; show the ones covering the current frame.
        engine.$subtitleCues.receive(on: DispatchQueue.main).sink { [weak self] cues in
            guard let self else { return }
            allCues = cues.compactMap { SubCue.make($0) }
            refreshActiveCues()
        }.store(in: &bag)
        engine.clock.$sourceTime.receive(on: DispatchQueue.main).sink { [weak self] t in
            guard let self else { return }
            sourceTime = Double(t)
            refreshActiveCues()
        }.store(in: &bag)
    }

    private func refreshActiveCues() {
        guard activeSubtitleID != nil else { if !activeCues.isEmpty { activeCues = [] }; return }
        let t = sourceTime
        let now = allCues.filter { $0.start <= t && t < $0.end }
        if now != activeCues { activeCues = now }
    }

    func refreshTracks() {
        guard let engine else { return }
        audioTracks = engine.audioTracks
        subtitleTracks = engine.subtitleTracks
        activeAudioID = Reflect.int(engine.activeAudioTrackIndex)
        activeSubtitleID = Reflect.int(engine.activeSubtitleTrackIndex)
        refreshActiveCues()
    }

    func selectSubtitle(_ t: TrackInfo?) {
        guard let engine else { return }
        if let t { engine.selectSubtitleTrack(index: t.id); activeSubtitleID = Reflect.int(t.id) }
        else { engine.clearSubtitle(); activeSubtitleID = nil; activeCues = [] }
        refreshActiveCues()
    }

    func selectAudio(_ t: TrackInfo) {
        engine?.selectAudioTrack(index: t.id)
        activeAudioID = Reflect.int(t.id)
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
            SubtitleOverlay(cues: model.activeCues, lift: showControls ? 110 : 0)
                .animation(.easeInOut(duration: 0.2), value: showControls)
            Color.clear.contentShape(Rectangle()).onTapGesture { toggleControls() }
            if model.isPaused && model.error == nil { pausedOverlay }
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
        .onChange(of: model.isPaused) { _, paused in
            if paused { withAnimation(.easeInOut(duration: 0.2)) { showControls = true } }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; finish() }
    }

    // MARK: Controls

    private var controls: some View {
        VStack {
            HStack(alignment: .top, spacing: 10) {
                glassButton("xmark", size: 44) { dismiss() }
                titleBlock.frame(maxWidth: .infinity, alignment: .leading)
                if !model.subtitleTracks.isEmpty { subtitleMenu }
                if model.audioTracks.count > 1 { audioMenu }
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

    /// "Series name" over "S1 · E3 · Episode title", or the movie name over its year.
    private var subtitleLine: String? {
        if let s = request.season, let e = request.episode {
            var t = "S\(s) · E\(e)"
            if let n = request.episodeTitle, !n.isEmpty { t += " · \(n)" }
            return t
        }
        return request.item.releaseInfo
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(request.item.name).font(.headline).lineLimit(1)
            if let l = subtitleLine { Text(l).font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(minHeight: 44)
        .glassEffect(.regular, in: .capsule)
    }

    private var subtitleMenu: some View {
        Menu {
            Button { model.selectSubtitle(nil) } label: {
                if model.activeSubtitleID == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            ForEach(model.subtitleTracks, id: \.id) { t in
                Button { model.selectSubtitle(t) } label: {
                    let title = Reflect.trackTitle(t)
                    if Reflect.int(t.id) == model.activeSubtitleID { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            Image(systemName: model.activeSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: .circle)
    }

    private var audioMenu: some View {
        Menu {
            ForEach(model.audioTracks, id: \.id) { t in
                Button { model.selectAudio(t) } label: {
                    let title = Reflect.trackTitle(t)
                    if Reflect.int(t.id) == model.activeAudioID { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            Image(systemName: "speaker.wave.2").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: .circle)
    }

    /// Title art when paused: TVDB clear logo if we have it, else the add-on's logo, else Metahub's, else the name as text.
    private var logoURL: URL? {
        if let l = request.logo { return l }
        if let l = request.item.logo.flatMap(URL.init(string:)) { return l }
        return URL(string: "https://images.metahub.space/logo/medium/\(request.imdb)/img")
    }

    private var pausedOverlay: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 12) {
                TitleLogo(url: logoURL, fallback: request.item.name).frame(maxWidth: 300, maxHeight: 90)
                if let l = subtitleLine { Text(l).font(.headline).foregroundStyle(.white.opacity(0.85)) }
            }
            .padding(.top, 84)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
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

/// Loads a title logo through the shared image pipeline; shows the title as text when there is no logo.
private struct TitleLogo: View {
    let url: URL?
    let fallback: String
    @State private var image: UIImage?
    @State private var finished = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().shadow(color: .black.opacity(0.5), radius: 8)
            } else if finished {
                Text(fallback).font(.largeTitle.bold()).multilineTextAlignment(.center).lineLimit(2).foregroundStyle(.white)
            }
        }
        .task(id: url) {
            finished = false; image = nil
            if let url { image = await ImagePipeline.shared.image(for: url, maxPixel: 900) }
            finished = true
        }
    }
}
