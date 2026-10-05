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
    /// Episode still (or movie backdrop): shown on the Continue Watching card.
    var thumb: URL? = nil
    /// Which add-on / release name this came from, so the next episode can prefer the same source.
    var sourceAddonID: String? = nil
    var sourceSignature: String? = nil
}

/// Playback position lives in its own object: only the seek bar observes it, so the 4 Hz clock
/// never re-renders the rest of the player.
@MainActor @Observable
final class Playhead {
    var position: Double = 0
    var duration: Double = 0
    @ObservationIgnored var scrubbing = false
}

/// Thin wrapper over AetherEngine (FFmpeg demux + VideoToolbox hardware decode): plays MKV, AVI, WebM and
/// DTS / TrueHD / Opus audio, while the heavy lifting stays in Apple's hardware decoder.
@MainActor @Observable
final class PlayerModel {
    var isPlaying = false
    var isPaused = false
    var isBuffering = true
    /// Debounced `isBuffering`: short stalls don't flash a spinner.
    var showSpinner = true
    var error: String?
    var audioTracks: [TrackInfo] = []
    var subtitleTracks: [TrackInfo] = []
    var activeAudioID: Int?
    var activeSubtitleID: Int?
    var activeCues: [SubCue] = []
    private(set) var engine: AetherEngine?

    let playhead = Playhead()

    @ObservationIgnored private var bag = Set<AnyCancellable>()
    @ObservationIgnored private var allCues: [SubCue] = []
    @ObservationIgnored private var mappedCount = 0
    @ObservationIgnored private var mappedFirst: Double?
    @ObservationIgnored private var sourceTime: Double = 0
    @ObservationIgnored private var spinnerTask: Task<Void, Never>?
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var pendingTarget: Double?
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var preferredSubtitleLanguage: String?
    @ObservationIgnored private var autoSelectSubtitle = false

    /// `replacing`: the engine is already playing something else (episode switch).
    func start(_ r: PlayRequest, resume: Double?, replacing: Bool = false) async {
        guard !isShutDown else { return }
        if engine == nil {
            do { engine = try AetherEngine() }
            catch {
                self.error = "Couldn't start the player engine: \(error.localizedDescription)"
                setBuffering(false)
                return
            }
        }
        guard let engine else { return }
        bind(engine)
        resetForNewItem()
        do {
            if replacing { engine.stop() }
            try await engine.load(url: r.url, options: LoadOptions(httpHeaders: r.headers))
            // The screen may have been closed while the source was loading.
            if isShutDown { engine.stop(); return }
            engine.play()
            if let resume, resume > 30 { await engine.seek(to: resume) }
        } catch {
            self.error = error.localizedDescription
            setBuffering(false)
        }
    }

    private func resetForNewItem() {
        error = nil
        isPlaying = false; isPaused = false
        setBuffering(true); showSpinner = true
        playhead.position = 0; playhead.duration = 0
        seekTask?.cancel(); pendingTarget = nil; seekInFlight = false
        allCues = []; mappedCount = 0; mappedFirst = nil; activeCues = []
        activeSubtitleID = nil; subtitleTracks = []; audioTracks = []; activeAudioID = nil
        // Keep the viewer's subtitle language across episodes.
        autoSelectSubtitle = preferredSubtitleLanguage != nil
    }

    private func bind(_ engine: AetherEngine) {
        guard bag.isEmpty else { return }
        engine.$state.receive(on: DispatchQueue.main).sink { [weak self] s in
            guard let self else { return }
            switch s {
            case .playing: isPlaying = true; isPaused = false; setBuffering(false); error = nil; refreshTracks()
            case .paused: isPlaying = false; isPaused = true; setBuffering(false)
            case .loading, .seeking: isPaused = false; setBuffering(true)
            case .ended: isPlaying = false; isPaused = false; setBuffering(false)
            case .error: isPlaying = false; isPaused = false; setBuffering(false); error = "Playback failed (\(String(describing: s)))."
            default: break
            }
        }.store(in: &bag)
        engine.$duration.receive(on: DispatchQueue.main).sink { [weak self] d in
            self?.playhead.duration = Double(d)
        }.store(in: &bag)
        // 4 Hz is plenty for a progress bar.
        engine.clock.$currentTime
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] t in
                guard let self, !playhead.scrubbing, !seekInFlight else { return }
                playhead.position = Double(t)
            }.store(in: &bag)
        // Subtitle cues arrive as one cumulative list in source time; only new cues are converted.
        engine.$subtitleCues.receive(on: DispatchQueue.main).sink { [weak self] cues in
            self?.ingest(cues)
        }.store(in: &bag)
        engine.clock.$sourceTime
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] t in
                guard let self else { return }
                sourceTime = Double(t)
                refreshActiveCues()
            }.store(in: &bag)
    }

    // MARK: Buffering indicator

    private func setBuffering(_ on: Bool) {
        if isBuffering != on { isBuffering = on }
        spinnerTask?.cancel()
        if on {
            spinnerTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.showSpinner = true
            }
        } else if showSpinner {
            showSpinner = false
        }
    }

    // MARK: Subtitles

    /// The engine republishes the whole list as it grows. Converting every cue each time (via reflection)
    /// is quadratic work on the main thread, so only the tail is converted.
    private func ingest(_ cues: [SubtitleCue]) {
        let first = cues.first.map { Double($0.startTime) }
        if cues.count < mappedCount || first != mappedFirst { allCues = []; mappedCount = 0 }
        mappedFirst = first
        if cues.count > mappedCount {
            allCues += cues[mappedCount...].compactMap { SubCue.make($0) }
            mappedCount = cues.count
        }
        refreshActiveCues()
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
        if autoSelectSubtitle, !subtitleTracks.isEmpty {
            autoSelectSubtitle = false
            if activeSubtitleID == nil, let lang = preferredSubtitleLanguage,
               let t = subtitleTracks.first(where: { Reflect.string($0, "language") == lang && !Reflect.bool($0, "isForced") }) {
                selectSubtitle(t)
                return
            }
        }
        refreshActiveCues()
    }

    func selectSubtitle(_ t: TrackInfo?) {
        guard let engine else { return }
        allCues = []; mappedCount = 0; mappedFirst = nil
        if let t {
            engine.selectSubtitleTrack(index: t.id)
            activeSubtitleID = Reflect.int(t.id)
            preferredSubtitleLanguage = Reflect.string(t, "language")
            ingest(engine.subtitleCues)
        } else {
            engine.clearSubtitle()
            activeSubtitleID = nil
            activeCues = []
            preferredSubtitleLanguage = nil
        }
        refreshActiveCues()
    }

    func selectAudio(_ t: TrackInfo) {
        engine?.selectAudioTrack(index: t.id)
        activeAudioID = Reflect.int(t.id)
    }

    // MARK: Transport

    func togglePlay() { engine?.togglePlayPause() }

    private func clamp(_ t: Double) -> Double {
        min(max(t, 0), playhead.duration > 0 ? playhead.duration : max(t, 0))
    }

    /// Seek immediately (scrub release).
    func seek(to t: Double) async {
        seekTask?.cancel()
        pendingTarget = clamp(t)
        playhead.position = pendingTarget ?? t
        seekInFlight = true
        await commitSeek()
    }

    /// Relative skip. Rapid taps are merged into one seek: every seek on a remote file forces a rebuffer.
    func skip(by delta: Double) {
        let target = clamp((pendingTarget ?? playhead.position) + delta)
        pendingTarget = target
        playhead.position = target
        seekInFlight = true
        seekTask?.cancel()
        seekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            await commitSeek()
        }
    }

    private func commitSeek() async {
        guard let t = pendingTarget else { seekInFlight = false; return }
        pendingTarget = nil
        await engine?.seek(to: t)
        if pendingTarget == nil { seekInFlight = false }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        spinnerTask?.cancel(); seekTask?.cancel()
        bag.removeAll()
        engine?.stop()
    }
}

// MARK: - Player screen

private struct SubtitleSize: Identifiable {
    let name: String
    let value: Double
    var id: Double { value }
}

/// Fullscreen player. Controls are flat translucent shapes (not Liquid Glass): glass over live video
/// re-samples every frame, which costs GPU time and made taps unreliable.
struct PlayerScreen: View {
    let provider: EpisodeProvider?
    let onClose: () -> Void
    @Environment(WatchHistory.self) private var history
    @Environment(SimklStore.self) private var simkl
    @Environment(\.openURL) private var openURL
    @AppStorage("player.subScale") private var subScale = 1.0
    @State private var current: PlayRequest
    @State private var model = PlayerModel()
    @State private var showControls = true
    @State private var showEpisodes = false
    @State private var hideTask: Task<Void, Never>?
    @State private var scrobbled = false
    @State private var closing = false
    @State private var switching: Int?
    @State private var notice: String?

    private static let sizes = [
        SubtitleSize(name: "Small", value: 0.8), SubtitleSize(name: "Medium", value: 1.0),
        SubtitleSize(name: "Large", value: 1.3), SubtitleSize(name: "Extra large", value: 1.65),
        SubtitleSize(name: "Huge", value: 2.1),
    ]

    init(request: PlayRequest, provider: EpisodeProvider? = nil, onClose: @escaping () -> Void) {
        _current = State(initialValue: request)
        self.provider = provider
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine = model.engine { AetherPlayerSurface(engine: engine).ignoresSafeArea() }
            SubtitleOverlay(cues: model.activeCues, lift: showControls ? 84 : 0, scale: CGFloat(subScale))
                .animation(.easeInOut(duration: 0.2), value: showControls)
            Color.clear.contentShape(Rectangle()).onTapGesture { tapBackground() }
            if model.isPaused && model.error == nil && !showEpisodes { pausedOverlay }
            if model.showSpinner && model.error == nil && !showControls && !showEpisodes {
                ProgressView().controlSize(.large).tint(.white)
            }
            if showControls || model.error != nil { controls.transition(.opacity) }
            if showEpisodes, let provider { episodePanel(provider).transition(.move(edge: .bottom).combined(with: .opacity)) }
            if let e = model.error { errorCard(e) }
            if let n = notice { toast(n) }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(showControls ? .automatic : .hidden)
        .animation(.snappy(duration: 0.25), value: notice)
        .task { await begin() }
        .task {
            // Coarse 10 s tick: negligible wakeups, still good resume accuracy.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                save()
            }
        }
        .onChange(of: model.isPlaying) { _, playing in
            if playing && !scrobbled { scrobbled = true; simkl.scrobble("start", current, progress: 0) }
            if playing { scheduleHide() } else { hideTask?.cancel() }
        }
        .onChange(of: model.isPaused) { _, paused in
            if paused { withAnimation(.easeInOut(duration: 0.2)) { showControls = true } }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            // Normal exit goes through close(); this covers any other way the screen can go away.
            if !closing { finalizeCurrent(); model.shutdown() }
        }
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 110)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom).frame(height: 200)
            }
            .ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                transport
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 8)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            iconButton("xmark") { close() }
            Spacer()
            if !model.subtitleTracks.isEmpty { subtitleMenu }
            if model.audioTracks.count > 1 { audioMenu }
        }
    }

    private var transport: some View {
        HStack(spacing: 52) {
            transportButton("gobackward.10", size: 28) { model.skip(by: -10); scheduleHide() }
            ZStack {
                transportButton(model.isPlaying ? "pause.fill" : "play.fill", size: 44) { model.togglePlay(); scheduleHide() }
                    .opacity(model.showSpinner ? 0.25 : 1)
                if model.showSpinner { ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false) }
            }
            transportButton("goforward.10", size: 28) { model.skip(by: 10); scheduleHide() }
        }
    }

    /// Series name + episode directly above the seek bar. Tapping the name opens the episode carousel.
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { openEpisodes() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(current.item.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        if provider != nil { Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold)).opacity(0.85) }
                    }
                    if let l = subtitleLine {
                        Text(l).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(provider == nil)

            SeekBar(playhead: model.playhead,
                    onScrubStart: { hideTask?.cancel() },
                    onCommit: { t in Task { await model.seek(to: t); scheduleHide() } })
        }
    }

    /// "S1 · E3 · Episode title", or the movie's year.
    private var subtitleLine: String? {
        if let s = current.season, let e = current.episode {
            var t = "S\(s) · E\(e)"
            if let n = current.episodeTitle, !n.isEmpty { t += " · \(n)" }
            return t
        }
        return current.item.releaseInfo
    }

    // MARK: Buttons + menus

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { glyph(symbol) }
            .buttonStyle(PressableStyle())
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(.black.opacity(0.38), in: Circle())
            .padding(4)                      // 44 pt touch target
            .contentShape(Rectangle())
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 6)
                .contentTransition(.symbolEffect(.replace))
                .animation(.snappy(duration: 0.2), value: symbol)
                .frame(width: 64, height: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    @ViewBuilder private func checkLabel(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private var subtitleMenu: some View {
        Menu {
            Button { model.selectSubtitle(nil) } label: { checkLabel("Off", model.activeSubtitleID == nil) }
            ForEach(model.subtitleTracks, id: \.id) { t in
                Button { model.selectSubtitle(t) } label: {
                    checkLabel(Reflect.trackTitle(t), Reflect.int(t.id) == model.activeSubtitleID)
                }
            }
            Divider()
            Menu {
                Picker("Subtitle size", selection: $subScale) {
                    ForEach(Self.sizes) { Text($0.name).tag($0.value) }
                }
                .pickerStyle(.inline)
            } label: { Label("Subtitle size", systemImage: "textformat.size") }
        } label: {
            glyph(model.activeSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .menuIndicator(.hidden)
        .tint(.white)
    }

    private var audioMenu: some View {
        Menu {
            ForEach(model.audioTracks, id: \.id) { t in
                Button { model.selectAudio(t) } label: {
                    checkLabel(Reflect.trackTitle(t), Reflect.int(t.id) == model.activeAudioID)
                }
            }
        } label: { glyph("speaker.wave.2") }
        .menuIndicator(.hidden)
        .tint(.white)
    }

    // MARK: Episode carousel

    private func episodePanel(_ provider: EpisodeProvider) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            EpisodePanel(provider: provider, showName: current.item.name,
                         currentSeason: current.season, currentEpisode: current.episode,
                         switching: switching,
                         onSelect: { s, ep in switchEpisode(s, ep) },
                         onClose: { closeEpisodes() })
        }
    }

    private func openEpisodes() {
        guard provider != nil else { return }
        hideTask?.cancel()
        withAnimation(.snappy(duration: 0.3)) { showEpisodes = true; showControls = false }
    }

    private func closeEpisodes() {
        withAnimation(.snappy(duration: 0.3)) { showEpisodes = false; showControls = true }
        scheduleHide()
    }

    private func switchEpisode(_ s: Int, _ ep: EpisodeItem) {
        guard let provider, switching == nil else { return }
        if s == current.season, ep.id == current.episode { closeEpisodes(); return }
        switching = ep.id
        Task {
            let next = await provider.resolve(s, ep, current)
            switching = nil
            guard !closing else { return }
            guard let next else { flash("No playable source found for that episode"); return }
            finalizeCurrent()                 // save + scrobble the episode we are leaving
            current = next
            scrobbled = false
            withAnimation(.snappy(duration: 0.3)) { showEpisodes = false; showControls = true }
            await model.start(next, resume: resumePoint(for: next), replacing: true)
            scheduleHide()
        }
    }

    private func flash(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if notice == message { notice = nil }
        }
    }

    private func toast(_ message: String) -> some View {
        VStack {
            Text(message).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.black.opacity(0.78), in: Capsule())
                .padding(.top, 18)
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    // MARK: Paused + error

    /// Title art when paused: TVDB clear logo if we have it, else the add-on's logo, else Metahub's, else the name as text.
    private var logoURL: URL? {
        if let l = current.logo { return l }
        if let l = current.item.logo.flatMap(URL.init(string:)) { return l }
        return URL(string: "https://images.metahub.space/logo/medium/\(current.imdb)/img")
    }

    private var pausedOverlay: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 12) {
                TitleLogo(url: logoURL, fallback: current.item.name).frame(maxWidth: 300, maxHeight: 90)
                if let l = subtitleLine { Text(l).font(.headline).foregroundStyle(.white.opacity(0.85)) }
            }
            .padding(.top, 70)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
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
        await model.start(current, resume: resumePoint(for: current))
        scheduleHide()
    }

    private func resumePoint(for r: PlayRequest) -> Double? {
        if let e = history.entry(for: r.item.id), e.key == r.key, e.position > 30 { return e.position }
        return nil
    }

    private func tapBackground() {
        if showEpisodes { closeEpisodes(); return }
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard model.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, !model.playhead.scrubbing, !showEpisodes else { return }
            withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
        }
    }

    private func save() {
        let p = model.playhead.position, d = model.playhead.duration
        guard d > 0, p > 0 else { return }
        history.update(current.item, key: current.key, position: p, duration: d,
                       season: current.season, episode: current.episode,
                       episodeTitle: current.episodeTitle, thumb: current.thumb?.absoluteString)
    }

    /// Saves progress and tells Simkl we stopped. Used when leaving an episode (close or switch).
    private func finalizeCurrent() {
        hideTask?.cancel()
        save()
        let d = model.playhead.duration
        if d > 0 { simkl.scrobble("stop", current, progress: model.playhead.position / d * 100) }
    }

    /// X button. Dismisses first so it always responds instantly, then tears the engine down a moment later.
    private func close() {
        guard !closing else { return }
        closing = true
        finalizeCurrent()
        let m = model
        onClose()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            m.shutdown()
        }
    }

    private func open(_ prefix: String) {
        let enc = current.url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        if let u = URL(string: prefix + enc) { openURL(u) }
    }
}

// MARK: - Seek bar

/// Thin custom scrubber. Reads the playhead itself so only this view redraws on clock ticks.
private struct SeekBar: View {
    let playhead: Playhead
    var onScrubStart: () -> Void = {}
    let onCommit: (Double) -> Void
    @State private var dragValue: Double?

    private var shown: Double { dragValue ?? playhead.position }

    var body: some View {
        let dur = max(playhead.duration, 1)
        let active = dragValue != nil
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                let frac = min(max(shown / dur, 0), 1)
                let h: CGFloat = active ? 8 : 4
                let knob: CGFloat = active ? 18 : 10
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28)).frame(height: h)
                    Capsule().fill(.white).frame(width: w * frac, height: h)
                    Circle().fill(.white).frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.35), radius: 3)
                        .offset(x: w * frac - knob / 2)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if dragValue == nil { playhead.scrubbing = true; onScrubStart() }
                            dragValue = min(max(g.location.x / w, 0), 1) * dur
                        }
                        .onEnded { g in
                            let v = min(max(g.location.x / w, 0), 1) * dur
                            dragValue = nil
                            playhead.scrubbing = false
                            onCommit(v)
                        }
                )
                .animation(.snappy(duration: 0.15), value: active)
            }
            .frame(height: 28)

            HStack {
                Text(Fmt.clock(shown))
                Spacer()
                Text("-" + Fmt.clock(max(dur - shown, 0)))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
        }
    }
}

// MARK: - Episode panel

/// Bottom sheet over the video: season pills + a carousel of episode thumbnails.
private struct EpisodePanel: View {
    let provider: EpisodeProvider
    let showName: String
    let currentSeason: Int?
    let currentEpisode: Int?
    let switching: Int?
    let onSelect: (Int, EpisodeItem) -> Void
    let onClose: () -> Void

    @State private var season: Int
    @State private var episodes: [EpisodeItem] = []
    @State private var loading = true

    private let cardWidth: CGFloat = 220
    private var cardHeight: CGFloat { cardWidth * 9 / 16 }

    init(provider: EpisodeProvider, showName: String, currentSeason: Int?, currentEpisode: Int?,
         switching: Int?, onSelect: @escaping (Int, EpisodeItem) -> Void, onClose: @escaping () -> Void) {
        self.provider = provider
        self.showName = showName
        self.currentSeason = currentSeason
        self.currentEpisode = currentEpisode
        self.switching = switching
        self.onSelect = onSelect
        self.onClose = onClose
        _season = State(initialValue: currentSeason ?? provider.seasons.first?.id ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(showName).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32).background(.white.opacity(0.16), in: Circle())
                        .padding(6).contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 24)

            if provider.seasons.count > 1 { seasonPills }
            carousel
        }
        .foregroundStyle(.white)
        .padding(.top, 20).padding(.bottom, 12)
        .background {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.88), location: 0.3),
                                   .init(color: .black.opacity(0.95), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .task(id: season) {
            loading = true; episodes = []
            let list = await provider.episodes(season)
            guard !Task.isCancelled else { return }
            episodes = list; loading = false
        }
    }

    private var seasonPills: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(provider.seasons) { s in
                    Button { season = s.id } label: {
                        Text(s.title).font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(s.id == season ? Theme.accent : Color.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var carousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    if loading && episodes.isEmpty {
                        ProgressView().tint(.white).frame(width: cardWidth, height: cardHeight)
                    }
                    ForEach(episodes) { ep in card(ep).id(ep.id) }
                    if !loading && episodes.isEmpty {
                        Text("No episode list available for this season")
                            .font(.footnote).foregroundStyle(.white.opacity(0.7)).frame(height: cardHeight)
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
            .onChange(of: episodes.count) { _, _ in
                if season == currentSeason, let e = currentEpisode { proxy.scrollTo(e, anchor: .center) }
            }
        }
    }

    private func card(_ ep: EpisodeItem) -> some View {
        let isCurrent = season == currentSeason && ep.id == currentEpisode
        let extras = [ep.runtime.map { "\($0) min" }, ep.rating.map { String(format: "★ %.1f", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
        return Button { onSelect(season, ep) } label: {
            VStack(alignment: .leading, spacing: 6) {
                RemoteImage(url: ep.image, size: cardWidth)
                    .frame(width: cardWidth, height: cardHeight)
                    .overlay { LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom) }
                    .overlay(alignment: .bottomLeading) {
                        Text("E\(ep.id)").font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.6), in: Capsule()).padding(8)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isCurrent {
                            Label("Playing", systemImage: "waveform").font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.accent, in: Capsule()).padding(8)
                        }
                    }
                    .overlay {
                        if switching == ep.id {
                            ZStack { Color.black.opacity(0.55); ProgressView().tint(.white) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: isCurrent ? 2.5 : 0)
                    }
                Text(ep.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .frame(width: cardWidth, alignment: .leading)
                Text(extras.isEmpty ? " " : extras).font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(switching != nil)
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
