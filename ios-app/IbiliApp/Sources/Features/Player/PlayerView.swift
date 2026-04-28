import SwiftUI
import AVKit
import AVFoundation
import UIKit

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var isLoading = true
    @Published var errorText: String?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var availableQualities: [(qn: Int64, label: String)] = []
    @Published var currentQn: Int64 = 0
    @Published var rate: Float = 1.0 { didSet { applyRate() } }

    private var aid: Int64 = 0
    private var cid: Int64 = 0
    private var loadGeneration: UInt64 = 0
    private let discoveryQn: Int64 = 120

    func load(item: FeedItemDTO, preferredQn: Int64) async {
        if player != nil, aid == item.aid, cid == item.cid {
            AppLog.debug("player", "跳过重复播放器加载", metadata: [
                "aid": String(item.aid),
                "cid": String(item.cid),
            ])
            return
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        aid = item.aid; cid = item.cid
        isLoading = true; errorText = nil
        AppLog.info("player", "开始加载播放器", metadata: [
            "aid": String(item.aid),
            "cid": String(item.cid),
            "preferredQn": String(preferredQn),
        ])
        do {
            let initial = try await fetchPlayUrl(aid: item.aid, cid: item.cid, qn: max(preferredQn, discoveryQn))
            guard isCurrentLoad(generation, aid: item.aid, cid: item.cid) else { return }
            let qualities = normalizedQualities(from: initial)
            let targetQn = resolveTargetQn(preferredQn: preferredQn, qualities: qualities, fallback: initial.quality)
            let info = targetQn == initial.quality ? initial : try await fetchPlayUrl(aid: item.aid, cid: item.cid, qn: targetQn)
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
            player.automaticallyWaitsToMinimizeStalling = false
            self.player = player
            applyRate()
            self.player?.play()
            AppLog.info("player", "播放器已就绪", metadata: [
                "aid": String(item.aid),
                "cid": String(item.cid),
                "quality": String(resolvedInfo.quality),
                "available": finalQualities.map { String($0.qn) }.joined(separator: ","),
                "streamType": resolvedInfo.streamType,
                "separateAudio": resolvedInfo.audioUrl == nil ? "false" : "true",
                "videoCdn": prep.video.winnerHost,
                "videoOpenMs": String(prep.video.winnerElapsedMs),
                "audioCdn": prep.audio?.winnerHost ?? "-",
                "audioOpenMs": prep.audio.map { String($0.winnerElapsedMs) } ?? "-",
                "prepMs": String(prep.totalElapsedMs),
                "videoAttempts": prep.video.attempts.joined(separator: " | "),
                "audioAttempts": prep.audio?.attempts.joined(separator: " | ") ?? "-",
            ])
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

    func switchQuality(to qn: Int64) async {
        guard let player else { return }
        let generation = loadGeneration
        let resumeAt = player.currentTime()
        let wasPlaying = player.timeControlStatus == .playing
        AppLog.info("player", "开始切换清晰度", metadata: [
            "aid": String(aid),
            "cid": String(cid),
            "fromQn": String(currentQn),
            "toQn": String(qn),
        ])
        do {
            let info = try await fetchPlayUrl(aid: aid, cid: cid, qn: qn)
            guard isCurrentLoad(generation, aid: aid, cid: cid) else { return }
            let (resolvedInfo, prep) = try await makePlayableItem(from: info, aid: aid, cid: cid, qn: qn)
            guard isCurrentLoad(generation, aid: aid, cid: cid) else { return }
            player.replaceCurrentItem(with: prep.item)
            player.automaticallyWaitsToMinimizeStalling = false
            await player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
            applyRate()
            if wasPlaying { player.play() }
            self.availableQualities = normalizedQualities(from: resolvedInfo)
            self.currentQn = resolvedInfo.quality
            AppLog.info("player", "清晰度切换成功", metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "quality": String(resolvedInfo.quality),
                "resumeSec": String(format: "%.3f", resumeAt.seconds),
                "streamType": resolvedInfo.streamType,
                "separateAudio": resolvedInfo.audioUrl == nil ? "false" : "true",
                "videoCdn": prep.video.winnerHost,
                "videoOpenMs": String(prep.video.winnerElapsedMs),
                "audioCdn": prep.audio?.winnerHost ?? "-",
                "audioOpenMs": prep.audio.map { String($0.winnerElapsedMs) } ?? "-",
                "prepMs": String(prep.totalElapsedMs),
            ])
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
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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

    private func isCurrentLoad(_ generation: UInt64, aid: Int64, cid: Int64) -> Bool {
        generation == loadGeneration && self.aid == aid && self.cid == cid
    }

    private func makePlayableItem(from info: PlayUrlDTO,
                                  aid: Int64,
                                  cid: Int64,
                                  qn: Int64) async throws -> (PlayUrlDTO, PlayerItemPreparation) {
        do {
            return (info, try await PlayerItemFactory.makeItem(from: info))
        } catch {
            guard info.audioUrl != nil, info.streamType == "web_dash" else { throw error }
            AppLog.warning("player", "web DASH 资产加载失败，回退 tv_durl", metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "qn": String(qn),
                "error": error.localizedDescription,
            ])
            let compat = try await fetchTVPlayUrl(aid: aid, cid: cid, qn: qn)
            return (compat, try await PlayerItemFactory.makeItem(from: compat))
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
            await vm.load(item: item, preferredQn: Int64(settings.resolvedPreferredVideoQn()))
            await loadDanmaku()
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
                            Task { await vm.switchQuality(to: q.qn) }
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

    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback)
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

