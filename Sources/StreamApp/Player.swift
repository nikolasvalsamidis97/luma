import AppKit
import SwiftUI
import VLCKit
import StreamCore
import UniformTypeIdentifiers
import IOKit.pwr_mgt

/// VLCKit 3.7.2 calls this private Objective-C selector on every position update.
/// Its implementation uses UpdateSystemActivity(UsrActivity), waking keyboard lights.
/// Override only on our subclass; PlayerModel owns a display-only power assertion.
/// Recheck this selector when upgrading the pinned VLCKit binary.
final class LumaMediaPlayer: VLCMediaPlayer {
    @objc(delaySleep) dynamic func suppressLegacyUserActivity() {}
}

private final class PlaybackDisplayAssertion {
    private var id: IOPMAssertionID = 0
    func setActive(_ active: Bool) {
        if active, id == 0 {
            var created: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                          IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "Luma video playback" as CFString, &created) == kIOReturnSuccess {
                id = created
            }
        } else if !active, id != 0 {
            IOPMAssertionRelease(id); id = 0
        }
    }
    deinit { if id != 0 { IOPMAssertionRelease(id) } }
}

@MainActor final class PlayerModel: ObservableObject {
    @Published private(set) var engine: VLCMediaPlayer
    @Published private(set) var engineID = UUID()
    @Published private(set) var subtitleAppearance: SubtitleAppearance
    @Published private(set) var subtitleTracks: [SubtitleTrack] = []
    @Published private(set) var selectedSubtitle: Int32 = -1
    @Published private(set) var subtitleDelay: Double = 0
    @Published var subtitleError: String?
    @Published private(set) var audioTracks: [AudioTrack] = []
    @Published private(set) var selectedAudio: Int32 = -1
    @Published private(set) var qualities: [PlaybackQuality] = []
    @Published private(set) var selectedQualityID = "auto"
    var hasAdaptiveQualities: Bool { !hlsResolutions.isEmpty }
    var qualityLabel: String { qualities.first { $0.id == selectedQualityID }?.label ?? "Auto" }
    var onTraits: ((MediaTraits) -> Void)?
    var onProgress: ((PlaybackSnapshot) -> Void)?
    private var lastProgressReport = Date.distantPast
    private var lastReportedSnapshot: PlaybackSnapshot?
    private var restoringProgressPosition: Int32?
    func prepareResume(at seconds: Double) {
        guard !isLive, seconds.isFinite, seconds > 0 else { return }
        pendingResume = (Int32(min(seconds * 1000, Double(Int32.max))), false)
    }
    private var hlsResolutions: [VideoResolution] = []
    private var qualityTask: Task<Void, Never>?
    private var qualityDiscoveryFinished = false
    private var restoringAudio: AudioTrack?
    private var restoringVideo: Int32?
    private var preferredSubtitle: Int32?
    private var subtitleFiles: [URL] = []
    private var pauseAfterSeek: (deadline: Date, target: Int32)?
    private var pendingResume: (milliseconds: Int32, paused: Bool)?
    private var restoringSubtitle: Int32?
    private var restoredDelay = false
    private let isLive: Bool
    private let displayAssertion = PlaybackDisplayAssertion()
    init(isLive: Bool = false) {
        self.isLive = isLive
        let saved = UserDefaults.standard.data(forKey: "subtitle.appearance")
            .flatMap { try? JSONDecoder().decode(SubtitleAppearance.self, from: $0) }?.normalized ?? SubtitleAppearance()
        subtitleAppearance = saved
        engine = Self.makeEngine(saved, isLive: isLive)
    }
    // Luma owns volume/preferences. Disabling VLC volume persistence also avoids
    // its global config writer racing a newly created engine during reloads.
    private static func makeEngine(_ style: SubtitleAppearance, isLive: Bool, quality: VideoResolution? = nil) -> VLCMediaPlayer {
        #if PLAYER_DIAGNOSTICS
        let logging = ["--verbose=2"]
        #else
        let logging = ["--quiet"]
        #endif
        return LumaMediaPlayer(options: logging + ["--no-video-title-show", "--network-caching=\(isLive ? 1500 : 4000)", "--ignore-config", "--no-volume-save", "--no-disable-screensaver", "--videotoolbox", "--codec=videotoolbox,any", "--drop-late-frames", "--skip-frames"] + style.vlcOptions + (quality?.vlcOptions ?? []))
    }
    @Published var status = "Connecting…"
    @Published var playing = false
    @Published var finished = false
    @Published private(set) var nearEnd = false
    @Published var buffering = true
    @Published var failed = false
    @Published var position: Double = 0
    @Published var elapsed = "00:00"
    @Published var duration = "00:00"
    @Published var seekable = false
    @Published var volume: Double = 80 { didSet { engine.audio?.volume = Int32(volume) } }
    private var timer: Timer?
    private var url: URL?
    private var started = Date()
    private var lastProgress = Date()
    private var lastTime: Int32 = 0
    private var hasAdvanced = false
    private var userPaused = false
    private var nextTrackRefresh = Date.distantPast
    func play(_ url: URL) {
        if self.url != nil && self.url != url {
            hlsResolutions = []; qualities = []; selectedQualityID = "auto"; qualityDiscoveryFinished = false
        }
        stop(); self.url = url; started = Date(); lastProgress = Date(); lastTime = 0; hasAdvanced = false; userPaused = false; finished = false; status = "Connecting…"; buffering = true; failed = false
        restoredDelay = false; pauseAfterSeek = nil; nextTrackRefresh = .distantPast
        nearEnd = false; position = 0; elapsed = "00:00"; duration = "00:00"; seekable = false
        lastProgressReport = .distantPast; lastReportedSnapshot = nil
        restoringProgressPosition = pendingResume?.milliseconds
        let media = VLCMedia(url: url)
        if let resume = pendingResume, resume.milliseconds > 0 {
            media.addOptions(["start-time": Double(resume.milliseconds) / 1000])
        }
        if !subtitleFiles.isEmpty { media.addOptions(["sub-file": subtitleFiles.last!.path]) }
        engine.media = media
        engine.audio?.volume = Int32(volume)
        engine.play()
        displayAssertion.setActive(true)
        discoverQualities(url)
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }
    func retry() { if let url { play(url) } }
    func stop() { if timer != nil { reportProgress() }; qualityTask?.cancel(); qualityTask = nil; timer?.invalidate(); timer = nil; engine.stop(); playing = false; buffering = false; displayAssertion.setActive(false) }
    func toggle() { pauseAfterSeek = nil; if finished { retry(); return }; if engine.isPlaying { reportProgress(); userPaused = true; engine.pause(); displayAssertion.setActive(false) } else { userPaused = false; lastProgress = Date(); engine.play(); displayAssertion.setActive(true) } }
    func playNextItem(_ url: URL) {
        let previous = engine
        stop(); previous.drawable = nil
        // Stream-local track IDs, external subtitles and quality caps cannot carry to another episode.
        subtitleFiles = []; preferredSubtitle = nil; restoringSubtitle = nil; subtitleTracks = []; selectedSubtitle = -1
        subtitleDelay = 0; subtitleError = nil; pendingResume = nil; pauseAfterSeek = nil
        restoringAudio = nil; restoringVideo = nil; audioTracks = []; selectedAudio = -1
        hlsResolutions = []; qualities = []; selectedQualityID = "auto"; qualityDiscoveryFinished = false
        engine = Self.makeEngine(subtitleAppearance, isLive: isLive); engineID = UUID()
        play(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = previous }
    }
    func seek(_ value: Double) { restoringProgressPosition = nil; engine.position = Float(value) }
    func skip(_ seconds: Int32) { engine.jumpForward(seconds) }
    func selectSubtitle(_ id: Int32) {
        preferredSubtitle = id; selectedSubtitle = id; restoringSubtitle = nil
        engine.currentVideoSubTitleIndex = id
        engine.currentVideoSubTitleDelay = SubtitleAppearance.delayMicroseconds(subtitleDelay)
    }
    func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = Double(SubtitleAppearance.delayMicroseconds(seconds)) / 1_000_000
        engine.currentVideoSubTitleDelay = SubtitleAppearance.delayMicroseconds(subtitleDelay)
    }
    func chooseSubtitleFile() {
        let panel = NSOpenPanel()
        panel.title = "Add subtitles"
        panel.allowedContentTypes = ["srt", "vtt", "ass", "ssa", "sub"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.loadSubtitleFile(url) }
        }
    }
    func loadSubtitleFile(_ file: URL) {
        subtitleError = nil
        guard FileManager.default.isReadableFile(atPath: file.path) else { subtitleError = "This subtitle file couldn’t be read."; return }
        let result = engine.addPlaybackSlave(file, type: .subtitle, enforce: true)
        guard result == 0 else { subtitleError = "Couldn’t load subtitles. Try an SRT, WebVTT, or ASS file during playback."; return }
        subtitleFiles = [file]; preferredSubtitle = nil; restoringSubtitle = nil
    }
    func applySubtitleAppearance(_ style: SubtitleAppearance) {
        let updated = style.normalized
        guard updated != subtitleAppearance else { return }
        subtitleAppearance = updated
        if let data = try? JSONEncoder().encode(updated) { UserDefaults.standard.set(data, forKey: "subtitle.appearance") }
        reloadEngine()
    }
    func selectAudio(_ id: Int32) {
        guard audioTracks.contains(where: { $0.id == id }) else { return }
        restoringAudio = nil; engine.currentAudioTrackIndex = id; selectedAudio = id
    }
    func selectQuality(_ id: String) {
        guard id != selectedQualityID else { return }
        if id == "auto", hasAdaptiveQualities { selectedQualityID = id; reloadEngine(); return }
        guard let quality = qualities.first(where: { $0.id == id }) else { return }
        selectedQualityID = id
        if let track = quality.videoTrackID { engine.currentVideoTrackIndex = track }
        else { reloadEngine() }
    }
    private func reloadEngine() {
        let resume = pendingResume ?? pauseAfterSeek.map { ($0.target, true) } ??
            (!isLive && engine.isSeekable ? (max(0, engine.time.intValue), userPaused || finished) : nil)
        let track = preferredSubtitle ?? restoringSubtitle ?? engine.currentVideoSubTitleIndex
        let audio = restoringAudio ?? audioTracks.first { $0.id == engine.currentAudioTrackIndex }
        let video = hasAdaptiveQualities ? nil : qualities.first { $0.id == selectedQualityID }?.videoTrackID
        let previous = engine
        stop(); previous.drawable = nil
        let resolution = hlsResolutions.first { "hls:\($0.id)" == selectedQualityID }
        engine = Self.makeEngine(subtitleAppearance, isLive: isLive, quality: resolution); engineID = UUID()
        subtitleTracks = []; selectedSubtitle = -1; audioTracks = []; selectedAudio = -1
        pendingResume = resume; restoringSubtitle = track; restoringAudio = audio; restoringVideo = video
        if let url { play(url) }
        // Keep the old engine alive while VLC tears down its asynchronous outputs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = previous }
    }
    private func discoverQualities(_ source: URL) {
        guard !qualityDiscoveryFinished, HLSQualityDiscovery.supports(source) else { return }
        qualityTask = Task { [weak self] in
            do {
                let resolutions = try await HLSQualityDiscovery.load(source)
                try Task.checkCancellation()
                guard let self, self.url == source else { return }
                self.qualityDiscoveryFinished = true
                guard resolutions.count > 1 else { return }
                self.hlsResolutions = resolutions
                self.qualities = resolutions.map { PlaybackQuality(id: "hls:\($0.id)", label: $0.label, resolution: $0, videoTrackID: nil) }
            } catch { /* Discovery is optional; playback continues even if a provider blocks it. */ }
        }
    }
    private func updateMediaTracks() {
        let names = engine.audioTrackNames as? [String] ?? []
        let indexes = engine.audioTrackIndexes as? [NSNumber] ?? []
        var seen = Set<Int32>()
        let audio = zip(indexes, names).compactMap { index, name -> AudioTrack? in
            let id = index.int32Value
            guard id >= 0, seen.insert(id).inserted else { return nil }
            return AudioTrack(id: id, name: name.isEmpty ? "Track \(id)" : name)
        }
        if audio != audioTracks { audioTracks = audio }
        if let wanted = restoringAudio, let match = audio.first(where: { $0 == wanted }) ?? audio.first(where: { $0.name == wanted.name }) {
            engine.currentAudioTrackIndex = match.id; restoringAudio = nil
        }
        if selectedAudio != engine.currentAudioTrackIndex { selectedAudio = engine.currentAudioTrackIndex }
        let info = engine.media?.tracksInformation as? [[String: Any]] ?? []
        if !hasAdaptiveQualities {
            let activeIDs = Set((engine.videoTrackIndexes as? [NSNumber] ?? []).map(\.int32Value))
            var known = Set<Int32>()
            let video = info.compactMap { track -> PlaybackQuality? in
                guard track[VLCMediaTracksInformationType] as? String == VLCMediaTracksInformationTypeVideo,
                      let id = (track[VLCMediaTracksInformationId] as? NSNumber)?.int32Value, id >= 0,
                      activeIDs.contains(id), known.insert(id).inserted,
                      let width = (track[VLCMediaTracksInformationVideoWidth] as? NSNumber)?.intValue,
                      let height = (track[VLCMediaTracksInformationVideoHeight] as? NSNumber)?.intValue,
                      width > 0, height > 0 else { return nil }
                let size = VideoResolution(width: width, height: height)
                return PlaybackQuality(id: "track:\(id)", label: size.label, resolution: size, videoTrackID: id)
            }.sorted { $0.resolution.height < $1.resolution.height }
            let choices = Set(video.map(\.resolution)).count > 1 ? video : []
            if choices != qualities { qualities = choices }
            if let id = restoringVideo, video.contains(where: { $0.videoTrackID == id }) {
                engine.currentVideoTrackIndex = id; restoringVideo = nil
            }
            let current = "track:\(engine.currentVideoTrackIndex)"
            if !choices.isEmpty && selectedQualityID != current { selectedQualityID = current }
        }
        let size = engine.videoSize
        // Only embedded tracks count toward a thumbnail badge, not user-imported subtitle files.
        let subtitleCount = info.filter { $0[VLCMediaTracksInformationType] as? String == VLCMediaTracksInformationTypeText }.count
        onTraits?(MediaTraits(resolution: MediaTraits.resolution(width: Int(size.width), height: Int(size.height)),
                              multipleSubtitles: subtitleFiles.isEmpty && subtitleCount > 1))
    }
    private func updateSubtitles() {
        if let pause = pauseAfterSeek {
            let time = engine.time.intValue
            // HLS seeking can take several network round trips. Pause after a decoded
            // frame reaches the saved position, instead of freezing the opening frame.
            let reached = time > 0 && abs(Int64(time) - Int64(pause.target)) < 1500
            if reached || Date() >= pause.deadline {
                pauseAfterSeek = nil; userPaused = true; engine.pause()
            }
        }
        let names = engine.videoSubTitlesNames as? [String] ?? []
        let indexes = engine.videoSubTitlesIndexes as? [NSNumber] ?? []
        var seen = Set<Int32>()
        let tracks = zip(indexes, names).compactMap { index, name -> SubtitleTrack? in
            let id = index.int32Value
            guard id >= 0, seen.insert(id).inserted else { return nil }
            return SubtitleTrack(id: id, name: name.isEmpty ? "Track \(id)" : name)
        }
        if tracks != subtitleTracks { subtitleTracks = tracks }
        if engine.isPlaying || userPaused || engine.state == .paused {
            if let id = restoringSubtitle, id == -1 || tracks.contains(where: { $0.id == id }) {
                engine.currentVideoSubTitleIndex = id; preferredSubtitle = id; restoringSubtitle = nil
            }
            if !restoredDelay {
                engine.currentVideoSubTitleDelay = SubtitleAppearance.delayMicroseconds(subtitleDelay); restoredDelay = true
            }
            if let resume = pendingResume, engine.isSeekable, engine.time.intValue > 0 {
                engine.time = VLCTime(int: resume.milliseconds)
                pendingResume = nil
                // Let the first sought frame and subtitle cue decode before pausing.
                if resume.paused { pauseAfterSeek = (Date().addingTimeInterval(10), resume.milliseconds) }
            }
        }
        let current = engine.currentVideoSubTitleIndex
        if selectedSubtitle != current { selectedSubtitle = current }
    }
    func update() {
        updateSubtitles()
        if Date() >= nextTrackRefresh {
            updateMediaTracks(); nextTrackRefresh = Date().addingTimeInterval(1.5)
        }
        let now = Date()
        let currentTime = engine.time.intValue
        if currentTime != lastTime && currentTime > 0 {
            hasAdvanced = true; lastProgress = now; lastTime = currentTime
        }
        let length = engine.media?.length.intValue ?? 0
        finished = engine.state == .ended || (!userPaused && engine.state == .paused && length > 0 && currentTime > 0 && length - currentTime < 1500)
        if playing != engine.isPlaying { playing = engine.isPlaying }
        failed = failed || engine.state == .error
        let recentlyAdvanced = hasAdvanced && now.timeIntervalSince(lastProgress) < 1.2
        buffering = !failed && !finished && !userPaused && engine.state != .ended && !recentlyAdvanced &&
            (engine.state == .opening || engine.state == .buffering || !hasAdvanced)
        if buffering && now.timeIntervalSince(lastProgress) > 40 {
            engine.stop(); failed = true; buffering = false; status = "Connection timed out"
        } else if failed { status = "Unable to play this stream" }
        else if finished { status = "Finished" }
        else if userPaused || engine.state == .paused { status = "Paused" }
        else if engine.state == .ended { status = "Finished"; buffering = false }
        else if buffering { status = hasAdvanced ? "Buffering…" : "Connecting…" }
        else if playing || recentlyAdvanced { status = "Playing" }
        nearEnd = !isLive && !failed && EpisodeSequence.shouldOfferNext(elapsed: Double(currentTime) / 1000, duration: Double(length) / 1000, finished: finished)
        displayAssertion.setActive(!userPaused && !finished && !failed && (playing || buffering))
        position = max(0, min(1, Double(engine.position)))
        seekable = engine.isSeekable
        elapsed = engine.time.stringValue
        duration = engine.media?.length.stringValue ?? "00:00"
        if let target = restoringProgressPosition, currentTime > 0, currentTime >= target {
            restoringProgressPosition = nil
        }
        if finished || now.timeIntervalSince(lastProgressReport) >= 5 { reportProgress() }
    }
    private func reportProgress() {
        guard !isLive, !failed, restoringProgressPosition == nil, pendingResume == nil, pauseAfterSeek == nil else { return }
        let snapshot = PlaybackSnapshot(seconds: max(0, Double(engine.time.intValue) / 1000),
            duration: max(0, Double(engine.media?.length.intValue ?? 0) / 1000), finished: finished || engine.state == .ended)
        guard snapshot != lastReportedSnapshot, snapshot.seconds > 0 || snapshot.finished else { return }
        onProgress?(snapshot)
        lastReportedSnapshot = snapshot; lastProgressReport = Date()
    }
}

/// Keep a single video surface alive across fullscreen transitions and control visibility changes.
@MainActor final class PlayerVideoContainer: NSView {
    let video = VLCVideoView()
    weak var presentation: PlayerPresentation?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor; layer?.masksToBounds = true
        video.autoresizingMask = []; addSubview(video)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentation?.attach(to: self.window, videoView: self)
        }
    }
    override func layout() {
        super.layout()
        if video.frame != bounds { video.frame = bounds }
    }
}

struct VideoSurface: NSViewRepresentable {
    let player: PlayerModel
    let presentation: PlayerPresentation
    func makeNSView(context: Context) -> PlayerVideoContainer {
        let view = PlayerVideoContainer()
        view.presentation = presentation
        player.engine.drawable = view.video
        return view
    }
    func updateNSView(_ view: PlayerVideoContainer, context: Context) {}
}

struct PlayerScreen: View {
    @ObservedObject var player: PlayerModel
    let close: () -> Void
    let item: MediaItem
    let url: URL
    let client: XtreamClient?
    var episodes: [MediaItem] = []
    var episodeURL: ((MediaItem) throws -> URL)? = nil
    var episodeChanged: ((MediaItem) -> Void)? = nil
    @StateObject var presentation = PlayerPresentation()
    @State private var activeEpisode: MediaItem?
    @State private var nextEpisodeError: String?
    private var currentItem: MediaItem { activeEpisode ?? item }
    private var nextEpisode: MediaItem? { EpisodeSequence.next(after: currentItem, in: episodes) }
    @State private var showAudio = false
    @State private var showQuality = false
    @State private var showSubtitles = false
    @State private var guide: [GuideEntry] = []
    @State private var guideMessage = "Loading programme guide…"
    var body: some View {
        ZStack {
            video
                .padding(.top, presentation.isFullscreen ? 0 : 76)
                .padding(.bottom, presentation.isFullscreen ? 0 : (item.kind == .live ? 145 : 94))
            VStack(spacing: 0) {
                header.background(presentation.isFullscreen ? Color.black.opacity(0.78) : Theme.background)
                    .onHover { presentation.pointerOverControls = $0 }
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    controls
                    if !presentation.isFullscreen { programmeGuide }
                }.onHover { presentation.pointerOverControls = $0 }
            }
            .opacity(presentation.controlsVisible ? 1 : 0)
            .allowsHitTesting(presentation.controlsVisible)
            .accessibilityHidden(!presentation.controlsVisible)
            if player.nearEnd, let next = nextEpisode, episodeURL != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { playNext(next) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("Play next", systemImage: "play.fill").font(.headline)
                                Text(next.name).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                            }.frame(maxWidth: 260, alignment: .leading).padding(16)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Play next episode: \(next.name)")
                            .onHover { presentation.pointerOverControls = $0 }
                    }
                }.padding(.horizontal, 24).padding(.bottom, 110)
            }
        }.background(.black).foregroundStyle(.white).tint(Theme.accent).frame(minWidth: 760, minHeight: 580)
        .alert("Couldn’t open next episode", isPresented: Binding(get: { nextEpisodeError != nil }, set: { if !$0 { nextEpisodeError = nil } })) {
            Button("OK") { nextEpisodeError = nil }
        } message: { Text(nextEpisodeError ?? "") }
        .onChange(of: player.playing) { _, playing in presentation.isPlaying = playing }
        .onChange(of: showAudio || showQuality || showSubtitles) { _, open in presentation.controlsPinned = open }
        .task {
            player.play(url)
            if item.kind == .live, let client {
                do { guide = try await client.guide(for: item); guideMessage = "No programme guide supplied for this channel." }
                catch { guideMessage = "Programme guide is currently unavailable." }
            }
        }
        .onDisappear { presentation.detach(); player.stop(); player.engine.drawable = nil }
    }
    private var header: some View {
        HStack(spacing: 14) {
                Button { close() } label: { Image(systemName: "arrow.left").frame(width: 28, height: 28).contentShape(Rectangle()) }.buttonStyle(.plain)
                    .help(item.kind == .series ? "Back to episodes" : "Back to library")
                    .accessibilityLabel(item.kind == .series ? "Back to episodes" : "Back to library")
                VStack(alignment: .leading, spacing: 3) { Text(currentItem.name).font(.headline); Text(item.kind == .live ? "LIVE TV" : item.kind.title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent) }
                Spacer()
                Text(player.status).font(.caption).foregroundStyle(.secondary)
                Button { presentation.toggleFullscreen() } label: { Image(systemName: presentation.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain).help(presentation.isFullscreen ? "Exit full screen (Esc)" : "Enter full screen")
                    .accessibilityLabel(presentation.isFullscreen ? "Exit full screen" : "Enter full screen")
                    .keyboardShortcut("f", modifiers: [.control, .command])
            }.padding(20)
    }
    private func playNext(_ episode: MediaItem) {
        guard let episodeURL else { return }
        do {
            let nextURL = try episodeURL(episode)
            // Flush the outgoing episode before changing the progress callback's identity.
            player.stop()
            activeEpisode = episode
            presentation.pointerOverControls = false
            showAudio = false; showQuality = false; showSubtitles = false
            episodeChanged?(episode)
            player.playNextItem(nextURL)
            presentation.revealControls()
        } catch { nextEpisodeError = error.localizedDescription }
    }
    private var video: some View {
        ZStack {
                Color.black
                VideoSurface(player: player, presentation: presentation).id(player.engineID)
                if player.buffering { ProgressView(player.status).padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)) }
                if player.failed {
                    VStack(spacing: 16) {
                        Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                        Text("This stream couldn’t be played").font(.title3.bold())
                        Text("The stream may be offline or your provider’s connection limit may be reached.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try again") { player.retry() }.buttonStyle(.borderedProminent).tint(Theme.accent)
                    }.padding(32).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18)).frame(maxWidth: 470)
                }
            }.frame(minHeight: 300)
    }
    private var controls: some View {
        VStack(spacing: 14) {
                if item.kind != .live {
                    HStack { Text(player.elapsed).monospacedDigit(); Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...1).disabled(!player.seekable); Text(player.duration).monospacedDigit() }.font(.caption)
                }
                HStack(spacing: 24) {
                    Button { player.toggle() } label: { Image(systemName: player.finished ? "arrow.counterclockwise" : player.playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 28) }.help("Play or pause")
                    if item.kind == .live { Label("LIVE", systemImage: "circle.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent) }
                    Spacer()
                    if player.qualities.count > 1 {
                        Button { showQuality.toggle() } label: {
                            Text(player.qualityLabel).font(.system(size: 11, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 5)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        }.help("Playback quality").accessibilityLabel("Quality")
                            .popover(isPresented: $showQuality, arrowEdge: .top) { QualityControls(player: player).preferredColorScheme(.dark) }
                    }
                    Button { showAudio.toggle() } label: {
                        Image(systemName: "waveform").font(.system(size: 19)).foregroundStyle(showAudio ? Theme.accent : .white)
                    }.help("Choose audio track").accessibilityLabel("Audio")
                        .popover(isPresented: $showAudio, arrowEdge: .top) { AudioControls(player: player).preferredColorScheme(.dark) }
                    Button { showSubtitles.toggle() } label: {
                        Image(systemName: player.selectedSubtitle >= 0 ? "captions.bubble.fill" : "captions.bubble")
                            .font(.system(size: 19)).foregroundStyle(showSubtitles || player.selectedSubtitle >= 0 ? Theme.accent : .white)
                    }.help("Subtitles and appearance").accessibilityLabel("Subtitles")
                        .popover(isPresented: $showSubtitles, arrowEdge: .top) { SubtitleControls(player: player).preferredColorScheme(.dark) }
                    Button { player.volume = player.volume == 0 ? 80 : 0 } label: { Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") }.help("Mute or unmute")
                    Slider(value: $player.volume, in: 0...100).frame(width: 110).accessibilityLabel("Volume")
                }.buttonStyle(.plain)
            }.padding(20).background(Theme.panel)
    }
    @ViewBuilder private var programmeGuide: some View {
        if item.kind == .live {
                HStack(alignment: .top, spacing: 22) {
                    Text("ON THIS CHANNEL").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).padding(.top, 3)
                    if guide.isEmpty { Text(guideMessage).font(.caption).foregroundStyle(.secondary) }
                    else {
                        ForEach(Array(guide.prefix(3))) { entry in
                            VStack(alignment: .leading, spacing: 5) { Text(entry.isNow ? "NOW" : entry.start.formatted(date: .omitted, time: .shortened)).font(.caption2.bold()).foregroundStyle(Theme.accent); Text(entry.title).font(.caption).lineLimit(2) }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(20)
            }
    }
}


@MainActor final class PlayerWindowController: NSObject, NSWindowDelegate {
    static let shared = PlayerWindowController()
    private var window: NSWindow?
    private var model: PlayerModel?
    private weak var libraryWindow: NSWindow?
    func show(item: MediaItem, url: URL, client: XtreamClient?, episodes: [MediaItem] = [], episodeURL: ((MediaItem) throws -> URL)? = nil, episodeChanged: ((MediaItem) -> Void)? = nil,
              resumeAt: Double = 0, progress: ((MediaItem, PlaybackSnapshot) -> Void)? = nil) {
        let origin = NSApp.keyWindow
        close()
        libraryWindow = origin?.sheetParent ?? origin
        let model = PlayerModel(isLive: item.kind == .live)
        model.onTraits = { MediaFactsStore.shared.record($0, for: item) }
        model.onProgress = { progress?(item, $0) }
        model.prepareResume(at: resumeAt)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = item.name
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(Theme.background)
        window.minSize = NSSize(width: 760, height: 580)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.contentView = NSHostingView(rootView: PlayerScreen(player: model, close: { [weak self] in self?.goBack() }, item: item, url: url, client: client,
            episodes: episodes, episodeURL: episodeURL, episodeChanged: { [weak model, weak window] episode in
                window?.title = episode.name
                model?.onTraits = { MediaFactsStore.shared.record($0, for: episode) }
                model?.onProgress = { progress?(episode, $0) }
                episodeChanged?(episode)
            }).preferredColorScheme(.dark))
        self.model = model; self.window = window
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    func goBack() {
        let origin = libraryWindow
        close()
        origin?.makeKeyAndOrderFront(nil)
        origin?.attachedSheet?.makeKeyAndOrderFront(nil)
    }
    func close() { model?.stop(); window?.close(); window = nil; model = nil }
    func windowWillClose(_ notification: Notification) {
        model?.stop(); model?.engine.drawable = nil
        window?.contentView = nil; model = nil; window = nil
    }
}
