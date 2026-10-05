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

/// Playback position lives in its own object: only views that read it (seek bar, skip button) redraw on the
/// clock, never the whole player.
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
    var didEnd = false
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

    /// The viewer's default subtitle language (nil = off). Applied when tracks become available.
    func configure(defaultSubtitleLanguage lang: String?) {
        if preferredSubtitleLanguage == nil { preferredSubtitleLanguage = lang }
    }

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
        error = nil; didEnd = false
        isPlaying = false; isPaused = false
        setBuffering(true); showSpinner = true
        playhead.position = 0; playhead.duration = 0
        seekTask?.cancel(); pendingTarget = nil; seekInFlight = false
        allCues = []; mappedCount = 0; mappedFirst = nil; activeCues = []
        activeSubtitleID = nil; subtitleTracks = []; audioTracks = []; activeAudioID = nil
        // Default language on first start, then whatever the viewer picked, across episodes.
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
            case .ended: isPlaying = false; isPaused = false; setBuffering(false); didEnd = true
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
            if activeSubtitleID == nil, let lang = preferredSubtitleLanguage, let t = bestSubtitle(for: lang) {
                selectSubtitle(t)
                return
            }
        }
        refreshActiveCues()
    }

    /// Prefers a normal track, then a non-forced one, then anything in that language.
    private func bestSubtitle(for lang: String) -> TrackInfo? {
        let hits = subtitleTracks.filter {
            SubLanguages.matches(Reflect.string($0, "language"), lang) || SubLanguages.matches(Reflect.string($0, "name"), lang)
        }
        return hits.first { !Reflect.bool($0, "isForced") && !Reflect.bool($0, "isHearingImpaired") }
            ?? hits.first { !Reflect.bool($0, "isForced") } ?? hits.first
    }

    func selectSubtitle(_ t: TrackInfo?) {
        guard let engine else { return }
        allCues = []; mappedCount = 0; mappedFirst = nil
        if let t {
            engine.selectSubtitleTrack(index: t.id)
            activeSubtitleID = Reflect.int(t.id)
            preferredSubtitleLanguage = Reflect.string(t, "language") ?? Reflect.string(t, "name")
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

    /// Seek immediately (scrub release, skip-intro button).
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

// MARK: - Glass helpers

/// Liquid Glass when enabled, flat translucent fill otherwise (Settings → Playback).
private struct GlassCircle: ViewModifier {
    let on: Bool
    var tint: Color? = nil
    @ViewBuilder func body(content: Content) -> some View {
        if on {
            if let tint { content.glassEffect(.regular.tint(tint.opacity(0.55)), in: .circle) }
            else { content.glassEffect(.regular, in: .circle) }
        } else {
            content.background(tint?.opacity(0.75) ?? Color.black.opacity(0.4), in: Circle())
        }
    }
}

private struct GlassCapsule: ViewModifier {
    let on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.glassEffect(.regular, in: .capsule) }
        else { content.background(.black.opacity(0.55), in: Capsule()) }
    }
}

private struct GlassCard: ViewModifier {
    let on: Bool
    var radius: CGFloat = 26
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.glassEffect(.regular, in: .rect(cornerRadius: radius)) }
        else { content.background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: radius, style: .continuous)) }
    }
}

// MARK: - Player screen

struct PlayerScreen: View {
    let provider: EpisodeProvider?
    let onClose: () -> Void
    @Environment(WatchHistory.self) private var history
    @Environment(SimklStore.self) private var simkl
    @Environment(ThemeStore.self) private var theme
    @Environment(\.openURL) private var openURL
    @AppStorage(SubtitleStyle.storageKey) private var subJSON = ""
    @AppStorage("sub.lang") private var subLang = "off"
    @AppStorage("player.glass") private var glass = true
    @AppStorage("player.autoplayNext") private var autoplayNext = true
    @AppStorage("skip.fallbackSeconds") private var fallbackSkip = 85
    @State private var current: PlayRequest
    @State private var model = PlayerModel()
    @State private var showControls = true
    @State private var showEpisodes = false
    @State private var showSubtitles = false
    @State private var hideTask: Task<Void, Never>?
    @State private var scrobbled = false
    @State private var closing = false
    @State private var switching: Int?
    @State private var notice: String?
    @State private var nextEp: NextEpisode?
    @State private var segments: [SkipSegment] = []
    @State private var segmentsLoaded = false

    init(request: PlayRequest, provider: EpisodeProvider? = nil, onClose: @escaping () -> Void) {
        _current = State(initialValue: request)
        self.provider = provider
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine = model.engine { AetherPlayerSurface(engine: engine).ignoresSafeArea() }
            SubtitleOverlay(cues: model.activeCues, lift: showControls ? 118 : 0, style: SubtitleStyle.decode(subJSON))
                .animation(.easeInOut(duration: 0.2), value: showControls)
            Color.clear.contentShape(Rectangle()).onTapGesture { tapBackground() }
            if model.isPaused && model.error == nil && !showEpisodes && !showSubtitles { pausedOverlay }
            if model.showSpinner && model.error == nil && !showControls && !showEpisodes {
                ProgressView().controlSize(.large).tint(.white)
            }
            if showControls || model.error != nil { controls.transition(.opacity) }
            if !showEpisodes && !showSubtitles && model.error == nil { skipLayer }
            if showEpisodes, let provider { episodePanel(provider).transition(.move(edge: .bottom).combined(with: .opacity)) }
            if showSubtitles { subtitlePanel.transition(.move(edge: .trailing).combined(with: .opacity)) }
            if let e = model.error { errorCard(e) }
            if let n = notice { toast(n) }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(showControls ? .automatic : .hidden)
        .animation(.snappy(duration: 0.25), value: notice)
        .task { await begin() }
        .task(id: current.id) { await loadAux() }
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
        .onChange(of: model.didEnd) { _, ended in
            if ended, autoplayNext, nextEp != nil { playNext() }
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
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom).frame(height: 100)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom).frame(height: 230)
            }
            .ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack { circleButton("xmark", size: 42, icon: 16) { close() }; Spacer() }
                Spacer()
                transport
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 8)
        }
        .foregroundStyle(.white)
    }

    private var transport: some View {
        HStack(spacing: 38) {
            circleButton("gobackward.10", size: 50, icon: 21) { model.skip(by: -10); scheduleHide() }
            ZStack {
                circleButton(model.isPlaying ? "pause.fill" : "play.fill", size: 68, icon: 28) { model.togglePlay(); scheduleHide() }
                    .opacity(model.showSpinner ? 0.3 : 1)
                if model.showSpinner { ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false) }
            }
            circleButton("goforward.10", size: 50, icon: 21) { model.skip(by: 10); scheduleHide() }
        }
    }

    /// Series name + episode directly above the seek bar (tap the name for episodes), then the seek bar,
    /// then the icon row: subtitles, audio, next episode.
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

            iconRow
        }
    }

    private var iconRow: some View {
        HStack(spacing: 10) {
            if !model.subtitleTracks.isEmpty {
                circleButton(model.activeSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill",
                             size: 42, icon: 17, tint: showSubtitles ? theme.accent : nil) { toggleSubtitles() }
            }
            if model.audioTracks.count > 1 { audioMenu }
            Spacer()
            if nextEp != nil { nextButton }
        }
    }

    private var nextButton: some View {
        Button { playNext() } label: {
            HStack(spacing: 7) {
                if switching != nil { ProgressView().tint(.white).controlSize(.small) }
                else { Image(systemName: "forward.end.fill").font(.system(size: 13, weight: .bold)) }
                Text("Next").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: 42)
            .modifier(GlassCapsule(on: glass))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .disabled(switching != nil)
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

    // MARK: Buttons

    private func circleButton(_ symbol: String, size: CGFloat, icon: CGFloat, tint: Color? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: icon, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .animation(.snappy(duration: 0.2), value: symbol)
                .frame(width: size, height: size)
                .modifier(GlassCircle(on: glass, tint: tint))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }

    private var audioMenu: some View {
        Menu {
            ForEach(model.audioTracks, id: \.id) { t in
                Button { model.selectAudio(t) } label: {
                    checkLabel(Reflect.trackTitle(t), Reflect.int(t.id) == model.activeAudioID)
                }
            }
        } label: {
            Image(systemName: "speaker.wave.2").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 42, height: 42).modifier(GlassCircle(on: glass)).contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .tint(.white)
    }

    @ViewBuilder private func checkLabel(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    // MARK: Skip intro / next episode

    private var skipLayer: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                SkipOverlay(playhead: model.playhead, segments: segments, loaded: segmentsLoaded, hasNext: nextEp != nil,
                            fallback: (current.season != nil && fallbackSkip > 0 && showControls) ? Double(fallbackSkip) : nil,
                            glass: glass,
                            onSeek: { t in Task { await model.seek(to: t); scheduleHide() } },
                            onNext: { playNext() })
            }
            .padding(.trailing, 28)
            .padding(.bottom, showControls ? 140 : 40)
        }
        .animation(.snappy(duration: 0.25), value: showControls)
    }

    /// Timestamps from TheIntroDB, and which episode comes next. Both run again whenever the episode changes.
    private func loadAux() async {
        nextEp = nil; segments = []; segmentsLoaded = false
        let req = current
        async let found = IntroClient.shared.segments(item: req.item, imdb: req.imdb, season: req.season, episode: req.episode)
        if let provider, req.season != nil { nextEp = await provider.next(req) }
        let segs = await found
        guard !Task.isCancelled else { return }
        segments = segs; segmentsLoaded = true
    }

    private func playNext() {
        guard let n = nextEp else { return }
        switchEpisode(n.season, n.episode)
    }

    // MARK: Subtitle panel

    private var subtitlePanel: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Subtitles").font(.headline)
                    Spacer()
                    circleButton("xmark", size: 34, icon: 13) { closeSubtitles() }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(spacing: 6) {
                            trackRow("Off", on: model.activeSubtitleID == nil) { model.selectSubtitle(nil) }
                            ForEach(model.subtitleTracks, id: \.id) { t in
                                trackRow(Reflect.trackTitle(t), on: Reflect.int(t.id) == model.activeSubtitleID) { model.selectSubtitle(t) }
                            }
                        }
                        Text("APPEARANCE").font(.caption.weight(.bold)).tracking(1).foregroundStyle(.white.opacity(0.6))
                        SubtitleStyleControls(showsPreview: false, onDark: true)
                    }
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.hidden)
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(width: 340)
            .modifier(GlassCard(on: glass))
            .padding(.vertical, 10).padding(.trailing, 10)
        }
    }

    private func trackRow(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                if on { Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(theme.accent) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.white.opacity(on ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleSubtitles() {
        hideTask?.cancel()
        if showSubtitles { closeSubtitles(); return }
        // Controls get out of the way so the subtitles can be judged where they will really appear.
        withAnimation(.snappy(duration: 0.3)) { showSubtitles = true; showEpisodes = false; showControls = false }
    }

    private func closeSubtitles() {
        withAnimation(.snappy(duration: 0.3)) { showSubtitles = false; showControls = true }
        scheduleHide()
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
        withAnimation(.snappy(duration: 0.3)) { showEpisodes = true; showSubtitles = false; showControls = false }
    }

    private func closeEpisodes() {
        withAnimation(.snappy(duration: 0.3)) { showEpisodes = false; showControls = true }
        scheduleHide()
    }

    /// Jumps to another episode. `resolve` keeps the source you are watching now (same add-on and release name),
    /// then falls back to the pinned source, then to any playable stream.
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

    /// Title art when paused: the logo if we found one, otherwise the name as text.
    private var pausedOverlay: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 12) {
                TitleArt(item: current.item, maxWidth: 300, maxHeight: 90, font: .largeTitle.bold(), alignment: .center)
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
        model.configure(defaultSubtitleLanguage: subLang == "off" ? nil : subLang)
        await model.start(current, resume: resumePoint(for: current))
        scheduleHide()
    }

    private func resumePoint(for r: PlayRequest) -> Double? {
        if let e = history.entry(for: r.item.id), e.key == r.key, e.position > 30, !e.isFinished { return e.position }
        return nil
    }

    private func tapBackground() {
        if showEpisodes { closeEpisodes(); return }
        if showSubtitles { closeSubtitles(); return }
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard model.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, !model.playhead.scrubbing, !showEpisodes, !showSubtitles else { return }
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

// MARK: - Skip intro / next episode button

/// One floating button that changes with the moment: Skip Intro / Recap / Preview during those segments,
/// "Next Episode" in the credits or the last 45 s, and (when no timestamps exist) a manual skip while controls show.
private struct SkipOverlay: View {
    let playhead: Playhead
    let segments: [SkipSegment]
    let loaded: Bool
    let hasNext: Bool
    let fallback: Double?
    let glass: Bool
    let onSeek: (Double) -> Void
    let onNext: () -> Void

    private struct Choice { let title: String; let symbol: String; let target: Double? }   // nil target = next episode

    private var choice: Choice? {
        let p = playhead.position, d = playhead.duration
        guard d > 0 else { return nil }
        let seg = segments.first { p >= $0.start - 0.5 && p < ($0.end ?? d) - 1.5 }
        if hasNext && ((d - p <= 45 && p > 60) || seg?.kind == .credits) {
            return Choice(title: "Next Episode", symbol: "forward.end.fill", target: nil)
        }
        if let seg { return Choice(title: seg.label, symbol: "forward.fill", target: seg.end ?? d) }
        if loaded, segments.isEmpty, let f = fallback, p >= 3, p <= 420 {
            return Choice(title: "Skip \(Int(f))s", symbol: "goforward", target: p + f)
        }
        return nil
    }

    var body: some View {
        let c = choice
        ZStack {
            if let c {
                Button { if let t = c.target { onSeek(t) } else { onNext() } } label: {
                    Label(c.title, systemImage: c.symbol)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 20).frame(height: 44)
                        .modifier(GlassCapsule(on: glass))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: c?.title)
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
    @Environment(ThemeStore.self) private var theme

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
                            .background(s.id == season ? theme.accent : Color.white.opacity(0.14), in: Capsule())
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
                                .background(theme.accent, in: Capsule()).padding(8)
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
                            .strokeBorder(theme.accent, lineWidth: isCurrent ? 2.5 : 0)
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
