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
    private let discoveryQn: Int64 = 120

    func load(item: FeedItemDTO, preferredQn: Int64) async {
        aid = item.aid; cid = item.cid
        isLoading = true; errorText = nil
        AppLog.info("player", "开始加载播放器", metadata: [
            "aid": String(item.aid),
            "cid": String(item.cid),
            "preferredQn": String(preferredQn),
        ])
        do {
            let initial = try await fetchPlayUrl(aid: item.aid, cid: item.cid, qn: max(preferredQn, discoveryQn))
            let qualities = normalizedQualities(from: initial)
            let targetQn = resolveTargetQn(preferredQn: preferredQn, qualities: qualities, fallback: initial.quality)
            let info = targetQn == initial.quality ? initial : try await fetchPlayUrl(aid: item.aid, cid: item.cid, qn: targetQn)
            let finalQualities = normalizedQualities(from: info).isEmpty ? qualities : normalizedQualities(from: info)
            guard let url = URL(string: info.url) else {
                errorText = "无效的播放地址"; isLoading = false; return
            }
            self.availableQualities = finalQualities
            self.currentQn = info.quality
            self.player = AVPlayer(playerItem: makePlayerItem(url: url))
            applyRate()
            self.player?.play()
            AppLog.info("player", "播放器已就绪", metadata: [
                "aid": String(item.aid),
                "cid": String(item.cid),
                "quality": String(info.quality),
                "available": finalQualities.map { String($0.qn) }.joined(separator: ","),
            ])
        } catch {
            errorText = error.localizedDescription
            AppLog.error("player", "播放器加载失败", error: error, metadata: [
                "aid": String(item.aid),
                "cid": String(item.cid),
            ])
        }
        isLoading = false
    }

    func switchQuality(to qn: Int64) async {
        guard let player else { return }
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
            guard let url = URL(string: info.url) else { return }
            let newItem = makePlayerItem(url: url)
            player.replaceCurrentItem(with: newItem)
            await player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
            applyRate()
            if wasPlaying { player.play() }
            self.availableQualities = normalizedQualities(from: info)
            self.currentQn = info.quality
            AppLog.info("player", "清晰度切换成功", metadata: [
                "aid": String(aid),
                "cid": String(cid),
                "quality": String(info.quality),
                "resumeSec": String(format: "%.3f", resumeAt.seconds),
            ])
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

    private func makePlayerItem(url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": "Bilibili Freedoooooom/MarkII",
                "Referer": "https://www.bilibili.com/"
            ]
        ])
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        return item
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
        init(parent: PlayerContainer) { self.parent = parent }

        func playerViewController(_ vc: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            parent.onFullscreenChange(true)
        }
        func playerViewController(_ vc: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            parent.onFullscreenChange(false)
        }
    }
}

// MARK: - Player view

struct PlayerView: View {
    let item: FeedItemDTO
    @StateObject private var vm = PlayerViewModel()
    /// Plain reference type — see `DanmakuController` notes.
    @State private var danmaku = DanmakuController()
    @State private var isFullscreen = false
    @State private var lastDeviceOrientation: UIDeviceOrientation = .portrait
    /// Weak handle to the AVPlayerViewController so we can drive native FS.
    @State private var playerVCRef = PlayerVCBox()
    @EnvironmentObject private var settings: AppSettings

    private let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
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
                        onFullscreenChange: { fs in
                            isFullscreen = fs
                            if !fs { Orientation.request(.portrait) }
                        }
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

            Menu {
                ForEach(speedOptions, id: \.self) { s in
                    Button {
                        vm.rate = s
                    } label: {
                        if abs(s - vm.rate) < 0.01 {
                            Label(speedLabel(s), systemImage: "checkmark")
                        } else {
                            Text(speedLabel(s))
                        }
                    }
                }
            } label: { chip(icon: "gauge.with.dots.needle.50percent", text: speedLabel(vm.rate)) }

            Button {
                settings.danmakuEnabled.toggle()
            } label: {
                chip(icon: settings.danmakuEnabled ? "captions.bubble.fill" : "captions.bubble",
                     text: settings.danmakuEnabled ? "弹幕" : "弹幕关")
            }

            Button {
                enterFullscreen()
            } label: {
                chip(icon: "arrow.up.left.and.arrow.down.right", text: "全屏")
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

    private func speedLabel(_ s: Float) -> String {
        s == 1.0 ? "1.0x" : String(format: "%.2gx", s)
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

