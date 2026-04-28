import SwiftUI
import AVKit
import AVFoundation
import UIKit

@MainActor
final class PlayerViewModel: ObservableObject {
    enum PlayurlMode: String, Hashable {
        case autoWeb = "auto_web"
        case forceTV = "force_tv"
    }

    @Published var isLoading = true
    @Published var errorText: String?
    @Published private(set) var player: AVPlayer?
    /// `true` once the active `AVPlayerItem` has reached `.readyToPlay`.
    /// The view shows a loading spinner until this flips, so users never
    /// see AVKit's empty native chrome with a phantom pause icon while
    /// the master playlist + init segment are still loading from the
    /// local proxy.
    @Published private(set) var isVideoReady = false
    @Published private(set) var availableQualities: [(qn: Int64, label: String)] = []
    @Published var currentQn: Int64 = 0
    @Published var rate: Float = 1.0 { didSet { applyRate() } }

    private var aid: Int64 = 0
    private var cid: Int64 = 0
    private var loadGeneration: UInt64 = 0
    private let discoveryQn: Int64 = 120
    private var engine: PlaybackEngine = HLSProxyEngine.shared
    private var engineKind: PlayerEngineKind = .hlsProxy
    private var itemStatusObservation: NSKeyValueObservation?

    /// Set the active engine before calling `load`. Idempotent.
    func setEngine(_ kind: PlayerEngineKind) {
        guard kind != engineKind else { return }
        engine.tearDown()
        engineKind = kind
        engine = PlaybackEngineFactory.make(kind: kind)
    }

    func load(item: FeedItemDTO, preferredQn: Int64, playurlMode: PlayurlMode) async {
        if player != nil, aid == item.aid, cid == item.cid {
            AppLog.debug("player", "跳过重复播放器加载", metadata: [
                "aid": String(item.aid),
                "cid": String(item.cid),
            ])
            return
        }
        let startedAt = CFAbsoluteTimeGetCurrent()
        loadGeneration &+= 1
        let generation = loadGeneration
        aid = item.aid; cid = item.cid
        isLoading = true; errorText = nil; isVideoReady = false
        itemStatusObservation = nil
        AppLog.info("player", "开始加载播放器", metadata: [
            "aid": String(item.aid),
            "cid": String(item.cid),
            "preferredQn": String(preferredQn),
            "playurlMode": playurlMode.rawValue,
            "engine": engineKind.rawValue,
        ])
        do {
            let discoveryQnTarget = max(preferredQn, discoveryQn)
            let initial: PlayUrlDTO
            if let warm = PlayUrlPrefetcher.shared.take(aid: item.aid,
                                                       cid: item.cid,
                                                       qn: discoveryQnTarget,
                                                       playurlMode: playurlMode) {
                initial = warm
            } else {
                initial = try await fetchStartupPlayUrl(aid: item.aid,
                                                        cid: item.cid,
                                                        qn: discoveryQnTarget,
                                                        playurlMode: playurlMode)
            }
            guard isCurrentLoad(generation, aid: item.aid, cid: item.cid) else { return }
            let qualities = normalizedQualities(from: initial)
            let targetQn = resolveTargetQn(preferredQn: preferredQn, qualities: qualities, fallback: initial.quality)
            let info: PlayUrlDTO
            if targetQn == initial.quality {
                info = initial
            } else if let warm = PlayUrlPrefetcher.shared.take(aid: item.aid,
                                                                cid: item.cid,
                                                                qn: targetQn,
                                                                playurlMode: playurlMode) {
                info = warm
            } else {
                info = try await fetchStartupPlayUrl(aid: item.aid,
                                                     cid: item.cid,
                                                     qn: targetQn,
                                                     playurlMode: playurlMode)
            }
            guard isCurrentLoad(generation, aid: item.aid, cid: item.cid) else { return }
            let (resolvedInfo, prep) = try await makePlayableItem(from: info, aid: item.aid, cid: item.cid, qn: targetQn)
            guard isCurrentLoad(generation, aid: item.aid, cid: item.cid) else {
                AppLog.debug("player", "丢弃过期播放器加载结果", metadata: [
                    "aid": String(item.aid),
                    "cid": String(item.cid),
                ])
                return
            }
            let finalQualities = normalizedQualities(from: resolvedInfo).isEmpty ? qualities : normalizedQualities(from: resolvedInfo)
            self.availableQualities = finalQualities
            self.currentQn = resolvedInfo.quality
            let player = AVPlayer(playerItem: prep.item)
            // Leave `automaticallyWaitsToMinimizeStalling` at its default
            // (`true`). With our HLS proxy AVPlayer needs to fetch the
            // master + media playlists and the init segment before it can
            // emit frames; forcing the flag off makes it call `play()`
            // before there is anything to render and the playback gets
            // stuck at rate=1 with no frames (the user has to tap once to
            // unstick it).
            observeItemStatus(prep.item, generation: generation)
            self.player = player
            self.player?.play()
            applyRate()
            let startupMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            var meta = prep.logSummary
            meta["aid"] = String(item.aid)
            meta["cid"] = String(item.cid)
            meta["quality"] = String(resolvedInfo.quality)
            meta["available"] = finalQualities.map { String($0.qn) }.joined(separator: ",")
            meta["streamType"] = resolvedInfo.streamType
            meta["playurlMode"] = playurlMode.rawValue
            meta["separateAudio"] = resolvedInfo.audioUrl == nil ? "false" : "true"
            meta["prepMs"] = String(prep.totalElapsedMs)
            meta["startupMs"] = String(startupMs)
            AppLog.info("player", "播放器已就绪", metadata: meta)
            if playurlMode == .forceTV {
                AppLog.info("player", "tv_durl 探针", metadata: [
                    "aid": String(item.aid),
                    "cid": String(item.cid),
                    "requestedQn": String(targetQn),
                    "resolvedQn": String(resolvedInfo.quality),
                    "acceptQuality": resolvedInfo.acceptQuality.map(String.init).joined(separator: ","),
                    "acceptDescription": resolvedInfo.acceptDescription.joined(separator: ","),
                    "startupMs": String(startupMs),
                    "prepMs": String(prep.totalElapsedMs),
                ])
            }
            if let msg = resolvedInfo.debugMessage {
                AppLog.warning("player", "core 返回调试信息", metadata: ["detail": msg])
            }
        } catch {
            errorText = error.localizedDescription
            AppLog.error("player", "播放器加载失败", error: error, metadata: [
                "aid": String(item.aid),
                "cid": String(item.cid),
            ])
        }
        if isCurrentLoad(generation, aid: item.aid, cid: item.cid) {
            isLoading = false
        }
    }

    func switchQuality(to qn: Int64, playurlMode: PlayurlMode) async {
        guard let player else { return }
        let generation = loadGeneration
        let resumeAt = player.currentTime()
        let wasPlaying = player.timeControlStatus == .playing
        AppLog.info("player", "开始切换清晰度", metadata: [
            "aid": String(aid),
            "cid": String(cid),
            "fromQn": String(currentQn),
            "toQn": String(qn),
            "playurlMode": playurlMode.rawValue,
            "engine": engineKind.rawValue,
        ])
        do {
            // Releasing the previous source before allocating the new one
            // keeps the proxy token table from growing across switches.
            engine.tearDown()
            let info = try await fetchStartupPlayUrl(aid: aid, cid: cid, qn: qn, playurlMode: playurlMode)
            guard isCurrentLoad(generation, aid: aid, cid: cid) else { return }
            let (resolvedInfo, prep) = try await makePlayableItem(from: info, aid: aid, cid: cid, qn: qn)
            guard isCurrentLoad(generation, aid: aid, cid: cid) else { return }
            isVideoReady = false
            observeItemStatus(prep.item, generation: generation)
            player.replaceCurrentItem(with: prep.item)
            await player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
            applyRate()
            self.availableQualities = normalizedQualities(from: resolvedInfo)
            self.currentQn = resolvedInfo.quality
            var meta = prep.logSummary
            meta["aid"] = String(aid)
            meta["cid"] = String(cid)
            meta["quality"] = String(resolvedInfo.quality)
            meta["resumeSec"] = String(format: "%.3f", resumeAt.seconds)
            meta["streamType"] = resolvedInfo.streamType
            meta["playurlMode"] = playurlMode.rawValue
            meta["separateAudio"] = resolvedInfo.audioUrl == nil ? "false" : "true"
            meta["prepMs"] = String(prep.totalElapsedMs)
            AppLog.info("player", "清晰度切换成功", metadata: meta)
            if playurlMode == .forceTV {
                AppLog.info("player", "tv_durl 切换探针", metadata: [
                    "aid": String(aid),
                    "cid": String(cid),
                    "requestedQn": String(qn),
                    "resolvedQn": String(resolvedInfo.quality),
                    "acceptQuality": resolvedInfo.acceptQuality.map(String.init).joined(separator: ","),
                    "acceptDescription": resolvedInfo.acceptDescription.joined(separator: ","),
                    "prepMs": String(prep.totalElapsedMs),
                ])
            }
            if let msg = resolvedInfo.debugMessage {
                AppLog.warning("player", "core 返回调试信息", metadata: ["detail": msg])
            }
        } catch {
            errorText = error.localizedDescription
            AppLog.error("player", "清晰度切换失败", error: error, metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "toQn": String(qn),
            ])
        }
    }

    func teardown() {
        loadGeneration &+= 1
        AppLog.debug("player", "销毁播放器", metadata: [
            "aid": String(aid),
            "cid": String(cid),
        ])
        player?.pause()
        player = nil
        itemStatusObservation = nil
        isVideoReady = false
        engine.tearDown()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Wire a KVO observation that flips `isVideoReady` once the player
    /// item has buffered enough to render its first frame. The earlier
    /// generation guard ensures stale loads (rapid quality switches /
    /// dismissals) cannot resurrect a closed player.
    private func observeItemStatus(_ item: AVPlayerItem, generation: UInt64) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.loadGeneration == generation else { return }
                switch item.status {
                case .readyToPlay:
                    self.isVideoReady = true
                case .failed:
                    let detail = item.error?.localizedDescription ?? "unknown"
                    self.errorText = detail
                    AppLog.error("player", "AVPlayerItem 失败", error: item.error, metadata: [
                        "detail": detail,
                    ])
                default:
                    break
                }
            }
        }
    }

    private func fetchPlayUrl(aid: Int64, cid: Int64, qn: Int64) async throws -> PlayUrlDTO {
        try await Task.detached {
            try CoreClient.shared.playUrl(aid: aid, cid: cid, qn: qn)
        }.value
    }

    private func fetchTVPlayUrl(aid: Int64, cid: Int64, qn: Int64) async throws -> PlayUrlDTO {
        try await Task.detached {
            try CoreClient.shared.playUrlTV(aid: aid, cid: cid, qn: qn)
        }.value
    }

    private func fetchStartupPlayUrl(aid: Int64,
                                     cid: Int64,
                                     qn: Int64,
                                     playurlMode: PlayurlMode) async throws -> PlayUrlDTO {
        switch playurlMode {
        case .autoWeb:
            return try await fetchPlayUrl(aid: aid, cid: cid, qn: qn)
        case .forceTV:
            return try await fetchTVPlayUrl(aid: aid, cid: cid, qn: qn)
        }
    }

    private func isCurrentLoad(_ generation: UInt64, aid: Int64, cid: Int64) -> Bool {
        generation == loadGeneration && self.aid == aid && self.cid == cid
    }

    /// Build a player item from `info` using the active engine. If a
    /// `web_dash` source fails to prep on iOS, fall back to `tv_durl` —
    /// this is rare with the HLS proxy but kept as a safety net.
    private func makePlayableItem(from info: PlayUrlDTO,
                                  aid: Int64,
                                  cid: Int64,
                                  qn: Int64) async throws -> (PlayUrlDTO, EnginePreparation) {
        do {
            return (info, try await engine.makeItem(for: info))
        } catch {
            guard info.streamType == "web_dash" else { throw error }
            AppLog.warning("player", "web DASH 资产加载失败，回退 tv_durl", metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "qn": String(qn),
                "engine": engineKind.rawValue,
                "error": error.localizedDescription,
            ])
            let compat = try await fetchTVPlayUrl(aid: aid, cid: cid, qn: qn)
            return (compat, try await engine.makeItem(for: compat))
        }
    }

    private func normalizedQualities(from info: PlayUrlDTO) -> [(qn: Int64, label: String)] {
        let pairs = zip(info.acceptQuality, info.acceptDescription)
            .map { (qn: $0.0, label: $0.1) }
        let merged = Dictionary(uniqueKeysWithValues: pairs.map { ($0.qn, $0.label) })
        return merged.keys.sorted(by: >).map { ($0, merged[$0] ?? qualityLabel(for: $0)) }
    }

    private func resolveTargetQn(preferredQn: Int64,
                                 qualities: [(qn: Int64, label: String)],
                                 fallback: Int64) -> Int64 {
        let codes = Set(qualities.map(\.qn)).union([fallback])
        let sorted = codes.sorted(by: >)
        guard let highest = sorted.first else { return fallback }
        guard preferredQn > 0 else { return highest }
        return sorted.first(where: { $0 <= preferredQn }) ?? highest
    }

    private func qualityLabel(for qn: Int64) -> String {
        switch qn {
        case 120: return "4K"
        case 112: return "1080P+"
        case 80: return "1080P"
        case 64: return "720P"
        case 32: return "480P"
        case 16: return "360P"
        default: return "画质 \(qn)"
        }
    }

    private func applyRate() {
        guard let player else { return }
        player.rate = rate
        if rate != 0 { player.defaultRate = rate }
    }
}

// MARK: - Orientation helpers

enum Orientation {
    /// Request a specific interface-orientation set from the active scene.
    /// On iOS 16+ this is the public API; pre-16 falls back to the legacy
    /// `UIDevice.orientation` setter.
    static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        if #available(iOS 16, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            let value: UIDeviceOrientation
            switch mask {
            case .portrait:        value = .portrait
            case .landscapeLeft:   value = .landscapeRight   // swapped intentionally
            case .landscapeRight:  value = .landscapeLeft
            case .landscape:       value = .landscapeLeft
            default:               value = .portrait
            }
            UIDevice.current.setValue(value.rawValue, forKey: "orientation")
        }
    }
}

// MARK: - Player container (UIKit) hosting AVPlayerViewController + danmaku overlay

/// Wraps `AVPlayerViewController`. Critically, the danmaku overlay is mounted
/// inside `contentOverlayView`, which travels with the player into native
/// fullscreen — so danmaku stays visible there.
struct PlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    let danmaku: DanmakuController
    let danmakuEnabled: Bool
    let danmakuOpacity: Double
    /// Called once, with the just-created AVPlayerViewController. Lets the
    /// SwiftUI parent drive native fullscreen entry/exit.
    let onCreated: (AVPlayerViewController) -> Void
    /// Called when the user taps AVKit's native fullscreen button (or our own).
    let onFullscreenChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.loadViewIfNeeded()
        vc.player = player
        vc.delegate = context.coordinator
        DispatchQueue.main.async { onCreated(vc) }
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        vc.videoGravity = .resizeAspect

        // Mount the danmaku host inside the contentOverlayView so it persists
        // when AVKit moves the player into fullscreen.
        let host = UIHostingController(rootView: DanmakuOverlay(
            controller: danmaku,
            opacity: danmakuEnabled ? danmakuOpacity : 0
        ))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        if let overlay = vc.contentOverlayView {
            overlay.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: overlay.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            ])
        }
        context.coordinator.host = host
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        // Only attach the player on initial creation. iOS may briefly nil out
        // `vc.player` during fullscreen transitions; reassigning here would
        // cause playback to restart from zero. AVKit will re-attach itself.
        if vc.player == nil { vc.player = player }
        // Push opacity changes through to the hosting controller.
        context.coordinator.host?.rootView = DanmakuOverlay(
            controller: danmaku,
            opacity: danmakuEnabled ? danmakuOpacity : 0
        )
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var parent: PlayerContainer
        var host: UIHostingController<DanmakuOverlay>?
        private var rateBeforeTransition: Float = 1.0
        private var wasPlayingBeforeTransition = false
        init(parent: PlayerContainer) { self.parent = parent }

        func playerViewController(_ vc: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            capturePlaybackState(from: vc)
            parent.onFullscreenChange(true)
            coordinator.animate(alongsideTransition: nil) { [weak self, weak vc] _ in
                guard let self, let vc else { return }
                Orientation.request(.landscape)
                self.restorePlaybackState(on: vc)
            }
        }
        func playerViewController(_ vc: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            capturePlaybackState(from: vc)
            coordinator.animate(alongsideTransition: nil) { [weak self, weak vc] _ in
                guard let self, let vc else { return }
                self.parent.onFullscreenChange(false)
                Orientation.request(.portrait)
                self.restorePlaybackState(on: vc)
            }
        }

        private func capturePlaybackState(from vc: AVPlayerViewController) {
            wasPlayingBeforeTransition = vc.player?.timeControlStatus == .playing || (vc.player?.rate ?? 0) > 0
            let defaultRate = vc.player?.defaultRate ?? 0
            let activeRate = vc.player?.rate ?? 0
            rateBeforeTransition = activeRate > 0 ? activeRate : (defaultRate > 0 ? defaultRate : 1.0)
        }

        private func restorePlaybackState(on vc: AVPlayerViewController) {
            guard wasPlayingBeforeTransition, let player = vc.player else { return }
            player.playImmediately(atRate: rateBeforeTransition)
        }
    }
}

// MARK: - Player view

struct PlayerView: View {
    let item: FeedItemDTO
    @StateObject private var vm = PlayerViewModel()
    /// Plain reference type — see `DanmakuController` notes.
    @State private var danmaku = DanmakuController()
    @State private var didBootstrap = false
    @State private var isFullscreen = false
    @State private var lastDeviceOrientation: UIDeviceOrientation = .portrait
    /// Weak handle to the AVPlayerViewController so we can drive native FS.
    @State private var playerVCRef = PlayerVCBox()
    @EnvironmentObject private var settings: AppSettings

    private let orientationPublisher = NotificationCenter.default
        .publisher(for: UIDevice.orientationDidChangeNotification)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let p = vm.player {
                    PlayerContainer(
                        player: p,
                        danmaku: danmaku,
                        danmakuEnabled: settings.danmakuEnabled,
                        danmakuOpacity: settings.danmakuOpacity,
                        onCreated: { vc in playerVCRef.vc = vc },
                        onFullscreenChange: { fs in isFullscreen = fs }
                    )
                    // Cover the native chrome until the first frame is
                    // ready, otherwise users see a misleading pause icon
                    // hovering over a black surface during buffering.
                    if !vm.isVideoReady {
                        Color.black.opacity(0.85)
                        ProgressView().tint(.white)
                    }
                } else if vm.isLoading {
                    ProgressView().tint(.white)
                } else if let err = vm.errorText {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                            .foregroundStyle(.yellow)
                        Text(err).foregroundStyle(.white).multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
            .aspectRatio(16.0/9.0, contentMode: .fit)

            controlBar

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(.headline)
                    Text(item.author).font(.subheadline).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("AV", value: String(item.aid))
                    LabeledContent("BV", value: item.bvid)
                    LabeledContent("CID", value: String(item.cid))
                }
                .padding()
            }
        }
        .navigationTitle("播放")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            configureAudioSession()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            vm.setEngine(settings.playerEngine)
            // Run the video preparation and the danmaku fetch concurrently
            // so a slow danmaku endpoint can never hold up first frame.
            async let video: Void = vm.load(item: item,
                                            preferredQn: Int64(settings.resolvedPreferredVideoQn()),
                                            playurlMode: settings.forceTVPlayurl ? .forceTV : .autoWeb)
            async let danmaku: Void = loadDanmaku()
            _ = await (video, danmaku)
        }
        .onChange(of: vm.player) { newPlayer in
            if let p = newPlayer { danmaku.attach(p) }
        }
        .onReceive(orientationPublisher) { _ in
            handleDeviceOrientationChange()
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            if !isFullscreen {
                didBootstrap = false
                danmaku.detach()
                vm.teardown()
                Orientation.request(.portrait)
            }
        }
    }

    @ViewBuilder
    private var controlBar: some View {
        HStack(spacing: 10) {
            if !vm.availableQualities.isEmpty {
                Menu {
                    ForEach(vm.availableQualities, id: \.qn) { q in
                        Button {
                            Task {
                                await vm.switchQuality(to: q.qn,
                                                       playurlMode: settings.forceTVPlayurl ? .forceTV : .autoWeb)
                            }
                        } label: {
                            if q.qn == vm.currentQn {
                                Label(q.label, systemImage: "checkmark")
                            } else {
                                Text(q.label)
                            }
                        }
                    }
                } label: { chip(icon: "slider.horizontal.3", text: currentQualityLabel) }
            }

            Button {
                settings.danmakuEnabled.toggle()
            } label: {
                chip(icon: settings.danmakuEnabled ? "captions.bubble.fill" : "captions.bubble",
                     text: settings.danmakuEnabled ? "弹幕" : "弹幕关")
            }

            Spacer()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .contentShape(Capsule())
    }

    private var currentQualityLabel: String {
        vm.availableQualities.first { $0.qn == vm.currentQn }?.label ?? "清晰度"
    }

    private func loadDanmaku() async {
        AppLog.info("danmaku", "开始加载弹幕", metadata: [
            "cid": String(item.cid),
        ])
        do {
            let track = try await Task.detached { [cid = item.cid] in
                try CoreClient.shared.danmakuList(cid: cid)
            }.value
            danmaku.setItems(track.items)
            if let p = vm.player { danmaku.attach(p) }
            AppLog.info("danmaku", "弹幕加载完成", metadata: [
                "cid": String(item.cid),
                "count": String(track.items.count),
            ])
        } catch {
            AppLog.error("danmaku", "弹幕加载失败", error: error, metadata: [
                "cid": String(item.cid),
            ])
        }
    }

    /// Configure the shared audio session for video playback.
    ///
    /// `.playback` + `.moviePlayback` keeps audio playing when the screen
    /// locks (combined with the `audio` `UIBackgroundModes` entry in
    /// Info.plist), and `setActive(true)` is required so AVPlayer keeps
    /// pulling bytes from the local HLS proxy after the app goes to
    /// background — without it the in-process URLSession is throttled and
    /// playback stalls on the lock screen.
    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .moviePlayback, options: [])
            try s.setActive(true, options: [])
        } catch {
            AppLog.warning("player", "音频会话配置失败", metadata: [
                "error": error.localizedDescription,
            ])
        }
    }

    // MARK: - Fullscreen / orientation

    /// Enter native fullscreen and rotate to landscape. Uses AVKit's private
    /// transition selector — this is widely used in shipping apps and works
    /// reliably across iOS 14–17. Since this app isn't going through App
    /// Review, that's fine.
    private func enterFullscreen() {
        guard !isFullscreen else { return }
        isFullscreen = true
        AppLog.info("player", "请求进入全屏", metadata: [
            "aid": String(item.aid),
            "cid": String(item.cid),
        ])
        Orientation.request(.landscape)
        guard let vc = playerVCRef.vc else { return }
        let sel = NSSelectorFromString("enterFullScreenAnimated:completion:")
        if vc.responds(to: sel) {
            vc.perform(sel, with: true, with: nil)
        }
    }

    private func exitFullscreen() {
        guard isFullscreen else { return }
        isFullscreen = false
        AppLog.info("player", "请求退出全屏", metadata: [
            "aid": String(item.aid),
            "cid": String(item.cid),
        ])
        guard let vc = playerVCRef.vc else { return }
        let sel = NSSelectorFromString("exitFullScreenAnimated:completion:")
        if vc.responds(to: sel) {
            vc.perform(sel, with: true, with: nil)
        }
        Orientation.request(.portrait)
    }

    private func handleDeviceOrientationChange() {
        guard settings.autoRotateFullscreen else { return }
        let o = UIDevice.current.orientation
        guard o != lastDeviceOrientation else { return }
        defer { lastDeviceOrientation = o }
        if o.isLandscape, !isFullscreen {
            enterFullscreen()
        } else if o == .portrait, isFullscreen {
            exitFullscreen()
        }
    }
}

// MARK: - PlayerVC handle

final class PlayerVCBox {
    weak var vc: AVPlayerViewController?
}

