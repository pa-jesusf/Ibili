import AVFoundation
import SwiftUI

@MainActor
final class LiveRoomViewModel: ObservableObject {
    let sessionID: PlayerSessionID

    @Published private(set) var info: LiveRoomInfoDTO?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    @Published private(set) var availableQualities: [LiveQualityDTO] = []
    @Published private(set) var currentQn: Int64 = 0

    private var roomID: Int64 = 0

    init(sessionID: PlayerSessionID = PlayerSessionID()) {
        self.sessionID = sessionID
    }

    deinit {
        MainActor.assumeIsolated {
            player?.pause()
        }
    }

    func load(route: DeepLinkRouter.LiveRoute) async {
        guard route.roomID > 0 else { return }
        guard roomID != route.roomID || player == nil else { return }
        roomID = route.roomID
        isLoading = true
        errorText = nil
        player?.pause()
        player = nil

        let fetchedInfo: LiveRoomInfoDTO? = await Task.detached {
            try? CoreClient.shared.liveRoomInfo(roomID: route.roomID)
        }.value
        info = fetchedInfo

        do {
            let play = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.livePlayUrl(roomID: route.roomID)
            }.value
            configurePlayer(with: play, roomID: route.roomID)
        } catch {
            errorText = (error as NSError).localizedDescription
        }
        isLoading = false
    }

    func switchQuality(to qn: Int64) async {
        guard roomID > 0, qn != currentQn else { return }
        isLoading = true
        errorText = nil
        do {
            let play = try await Task.detached(priority: .userInitiated) { [roomID] in
                try CoreClient.shared.livePlayUrl(roomID: roomID, qn: qn)
            }.value
            configurePlayer(with: play, roomID: roomID)
        } catch {
            errorText = (error as NSError).localizedDescription
        }
        isLoading = false
    }

    func teardown() {
        player?.pause()
        player = nil
    }

    private func configurePlayer(with play: LivePlayUrlDTO, roomID: Int64) {
        guard let url = URL(string: play.url) else {
            errorText = "直播地址无效"
            return
        }
        let headers = [
            "User-Agent": BiliHTTP.userAgent,
            "Referer": "https://live.bilibili.com/\(roomID)",
        ]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        let nextPlayer = AVPlayer(playerItem: item)
        nextPlayer.automaticallyWaitsToMinimizeStalling = true
        player?.pause()
        player = nextPlayer
        currentQn = play.quality
        availableQualities = play.acceptQuality
        nextPlayer.play()
    }
}

struct LiveRoomView: View {
    let route: DeepLinkRouter.LiveRoute

    @StateObject private var vm: LiveRoomViewModel
    @State private var danmaku = DanmakuController()
    @State private var isFullscreen = false
    @EnvironmentObject private var router: DeepLinkRouter

    init(route: DeepLinkRouter.LiveRoute) {
        self.route = route
        _vm = StateObject(wrappedValue: LiveRoomViewModel(sessionID: route.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            playerSurface
                .aspectRatio(16.0 / 9.0, contentMode: .fit)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    roomTitle
                    anchorRow
                    if let err = vm.errorText {
                        offlinePanel(err)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(IbiliTheme.background)
        }
        .background(IbiliTheme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isFullscreen, !vm.availableQualities.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    qualityMenu
                }
            }
        }
        .task(id: route.roomID) {
            await vm.load(route: route)
        }
    }

    @ViewBuilder
    private var playerSurface: some View {
        ZStack {
            Color.black
            if let player = vm.player {
                PlayerContainer(
                    player: player,
                    sessionID: vm.sessionID,
                    title: resolvedTitle,
                    prefersLandscapeFullscreen: true,
                    danmaku: danmaku,
                    danmakuEnabled: false,
                    danmakuOpacity: 0,
                    danmakuBlockLevel: 0,
                    danmakuFrameRate: 60,
                    danmakuStrokeWidth: 1,
                    danmakuFontWeight: 400,
                    danmakuFontScale: 1,
                    isTemporarySpeedBoostActive: { false },
                    canBeginTemporarySpeedBoost: { false },
                    beginTemporarySpeedBoost: { false },
                    endTemporarySpeedBoost: {},
                    onCreated: { _ in },
                    onPresentationEvent: handlePresentationEvent,
                    onSwapOverlayReady: { _ in }
                )
            } else if vm.isLoading {
                ProgressView().tint(.white)
            } else if let err = vm.errorText {
                VStack(spacing: 12) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.86))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }

            if vm.isLoading, vm.player != nil {
                ProgressView().tint(.white)
                    .padding(12)
                    .background(Circle().fill(.black.opacity(0.35)))
            }
        }
    }

    private var roomTitle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("LIVE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(IbiliTheme.accent))
                if !resolvedWatchedLabel.isEmpty {
                    Text(resolvedWatchedLabel)
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
            }
            Text(resolvedTitle.isEmpty ? "直播间" : resolvedTitle)
                .font(.title3.weight(.bold))
                .foregroundStyle(IbiliTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var anchorRow: some View {
        Button {
            if let uid = vm.info?.uid, uid > 0 {
                router.openUserSpace(mid: uid)
            }
        } label: {
            HStack(spacing: 10) {
                RemoteImage(
                    url: vm.info?.anchorFace ?? "",
                    contentMode: .fill,
                    targetPointSize: CGSize(width: 44, height: 44),
                    quality: 90
                )
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 3) {
                    Text(resolvedAnchorName.isEmpty ? "主播" : resolvedAnchorName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IbiliTheme.textPrimary)
                    if !resolvedAreaText.isEmpty {
                        Text(resolvedAreaText)
                            .font(.caption)
                            .foregroundStyle(IbiliTheme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                if (vm.info?.uid ?? 0) > 0 {
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(IbiliTheme.surface)
            )
        }
        .buttonStyle(.plain)
        .disabled((vm.info?.uid ?? 0) <= 0)
    }

    private func offlinePanel(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
            Text(text)
                .font(.footnote)
                .foregroundStyle(IbiliTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(IbiliTheme.surface)
        )
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(vm.availableQualities) { quality in
                Button {
                    Task { await vm.switchQuality(to: quality.qn) }
                } label: {
                    if quality.qn == vm.currentQn {
                        Label(quality.label, systemImage: "checkmark")
                    } else {
                        Text(quality.label)
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .disabled(vm.isLoading)
    }

    private func handlePresentationEvent(_ event: PlayerPresentationEvent) {
        switch event {
        case .fullscreenChanged(let value, _):
            isFullscreen = value
        case .pictureInPictureRestoreRequested(_, let completion):
            completion(false)
        case .suppressTransientPauseObservation, .pictureInPictureChanged:
            break
        }
    }

    private var resolvedTitle: String {
        let value = vm.info?.title ?? route.title
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedAnchorName: String {
        let value = vm.info?.anchorName ?? route.anchorName
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedWatchedLabel: String {
        (vm.info?.watchedLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedAreaText: String {
        guard let info = vm.info else { return "" }
        if info.liveStatus == 1 {
            return "正在直播"
        }
        return ""
    }
}
