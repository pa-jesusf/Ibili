import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI

struct AnimePlayerView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var vm = AnimePlayerViewModel()
    @State private var presentationRouteActive = false
    @State private var lifecycleID = UUID()
    @State private var createdController: AVPlayerViewController?

    let route: DeepLinkRouter.AnimePlayerRoute

    var body: some View {
        VStack(spacing: 0) {
            playerSurface
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(route.subject.displayTitle)
                        .font(.title3.weight(.semibold))
                    Text(route.episode.displayTitle)
                        .font(.subheadline)
                        .foregroundStyle(IbiliTheme.textSecondary)
                    if !route.subject.summary.isEmpty {
                        VideoDescriptionView(desc: route.subject.summary, descV2: [])
                    }
                }
                .padding(16)
            }
        }
        .background(IbiliTheme.background)
        .navigationTitle(route.episode.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: route.id) {
            await vm.load(route: route)
        }
        .onAppear {
            lifecycleID = UUID()
        }
        .onDisappear {
            let id = lifecycleID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard id == lifecycleID else { return }
                PlayerAudioSessionCoordinator.shared.setSessionNeeded(false, by: vm)
                vm.stop()
            }
        }
        .tint(.white)
    }

    @ViewBuilder
    private var playerSurface: some View {
        ZStack {
            Color.black
            if let player = vm.player {
                PlayerContainer(
                    player: player,
                    sessionID: route.id,
                    title: route.play.title,
                    prefersLandscapeFullscreen: true,
                    isPresentationRouteActive: presentationRouteActive,
                    danmaku: vm.danmaku,
                    subtitle: nil,
                    subtitleEnabled: false,
                    danmakuEnabled: false,
                    danmakuOpacity: settings.danmakuOpacity,
                    danmakuBlockLevel: settings.resolvedDanmakuBlockLevel(),
                    danmakuFrameRate: settings.resolvedDanmakuFrameRate(),
                    danmakuStrokeWidth: settings.resolvedDanmakuStrokeWidth(),
                    danmakuFontWeight: settings.resolvedDanmakuFontWeight(),
                    danmakuFontScale: settings.resolvedDanmakuFontScale(),
                    isTemporarySpeedBoostActive: { false },
                    canBeginTemporarySpeedBoost: { false },
                    beginTemporarySpeedBoost: { false },
                    endTemporarySpeedBoost: {},
                    canRestorePlaybackAfterPresentation: { presentationRouteActive },
                    onCreated: { controller in
                        createdController = controller
                    },
                    onPresentationEvent: handlePresentationEvent
                )
            } else if vm.isLoading {
                ProgressView().tint(.white)
            } else if let errorText = vm.errorText {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text(errorText)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .foregroundStyle(.white)
            }
        }
    }

    private func handlePresentationEvent(_ event: PlayerPresentationEvent) {
        switch event {
        case .fullscreenChanged(let isFullscreen, _):
            presentationRouteActive = isFullscreen
            if isFullscreen {
                Orientation.activatePlayerPresentationRoute(route.id)
            } else {
                Orientation.deactivatePlayerPresentationRoute(route.id)
            }
        case .suppressTransientPauseObservation:
            break
        case .pictureInPictureChanged(let isActive, _):
            presentationRouteActive = isActive
        case .pictureInPictureRestoreRequested(_, let completion):
            completion(true)
        }
    }
}

@MainActor
final class AnimePlayerViewModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isLoading = false
    @Published var errorText: String?

    let danmaku = DanmakuController()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var markedWatched = false
    private weak var observedPlayer: AVPlayer?

    func load(route: DeepLinkRouter.AnimePlayerRoute) async {
        isLoading = true
        errorText = nil
        stop()
        defer { isLoading = false }

        guard let url = URL(string: route.play.url) else {
            errorText = "播放地址无效"
            return
        }

        var headers: [String: String] = [
            "User-Agent": route.play.userAgent.isEmpty ? BiliHTTP.headers["User-Agent"] ?? "" : route.play.userAgent,
        ]
        if !route.play.referer.isEmpty {
            headers["Referer"] = route.play.referer
        }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = [
            metadata(.commonIdentifierTitle, value: route.play.title),
        ].compactMap { $0 }
        let nextPlayer = AVPlayer(playerItem: item)
        nextPlayer.allowsExternalPlayback = true
        nextPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true
        nextPlayer.volume = AppSettings.shared.resolvedAudioVolumeLinear()
        PlayerAudioSessionCoordinator.shared.setSessionNeeded(true, by: self)
        player = nextPlayer
        configureNowPlaying(route: route)
        observeProgress(player: nextPlayer, route: route)
        nextPlayer.play()
    }

    func stop() {
        if let timeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeObserver = nil
        endObserver = nil
        observedPlayer = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func observeProgress(player: AVPlayer, route: DeepLinkRouter.AnimePlayerRoute) {
        observedPlayer = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.handleProgress(time.seconds, player: player, route: route)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.markWatched(route: route)
            }
        }
    }

    private func handleProgress(_ seconds: Double, player: AVPlayer, route: DeepLinkRouter.AnimePlayerRoute) {
        guard !markedWatched else { return }
        let duration = player.currentItem?.duration.seconds ?? 0
        guard duration.isFinite, duration > 60, seconds / duration >= 0.9 else { return }
        markWatched(route: route)
    }

    private func markWatched(route: DeepLinkRouter.AnimePlayerRoute) {
        guard !markedWatched,
              let session = BangumiSessionStore.load(),
              !session.accessToken.isEmpty else { return }
        markedWatched = true
        Task.detached(priority: .utility) {
            try? CoreClient.shared.animeEpisodeUpdate(
                accessToken: session.accessToken,
                subjectID: route.subject.id,
                episodeID: route.episode.id,
                collectionType: 2
            )
        }
    }

    private func configureNowPlaying(route: DeepLinkRouter.AnimePlayerRoute) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: route.play.title,
            MPMediaItemPropertyArtist: route.subject.displayTitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: 1,
        ]
        if let duration = player?.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    private func metadata(_ identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem? {
        guard !value.isEmpty else { return nil }
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item.copy() as? AVMetadataItem
    }
}
