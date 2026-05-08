import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class LiveRuntimeCoordinator {
    static let shared = LiveRuntimeCoordinator()

    private var viewModels: [PlayerSessionID: LiveRoomViewModel] = [:]

    func viewModel(for routeID: PlayerSessionID) -> LiveRoomViewModel {
        if let existing = viewModels[routeID] {
            return existing
        }
        let viewModel = LiveRoomViewModel(sessionID: routeID)
        viewModels[routeID] = viewModel
        return viewModel
    }

    func retainSessions(root: DeepLinkRouter.LiveRoute?, stack: [DeepLinkRouter.LiveRoute]) {
        let retainedIDs = Set(([root].compactMap { $0?.id }) + stack.map(\.id))
        for (routeID, viewModel) in viewModels where !retainedIDs.contains(routeID) {
            viewModel.teardown()
            viewModels.removeValue(forKey: routeID)
        }
    }
}

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
    private var cdnSelection: String = MediaCDNService.auto.rawValue
    private var playerTimeControlObservation: NSKeyValueObservation?

    init(sessionID: PlayerSessionID = PlayerSessionID()) {
        self.sessionID = sessionID
    }

    deinit {
        MainActor.assumeIsolated {
            teardown()
        }
    }

    func load(route: DeepLinkRouter.LiveRoute, cdnSelection: String = MediaCDNService.auto.rawValue) async {
        guard route.roomID > 0 else { return }
        let resolvedCdnSelection = cdnSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard roomID != route.roomID || self.cdnSelection != resolvedCdnSelection || player == nil else { return }
        roomID = route.roomID
        self.cdnSelection = resolvedCdnSelection
        isLoading = true
        errorText = nil
        stopCurrentPlayer(releaseAudioSession: true)

        let fetchedInfo: LiveRoomInfoDTO? = await Task.detached {
            try? CoreClient.shared.liveRoomInfo(roomID: route.roomID)
        }.value
        info = fetchedInfo

        do {
            let play = try await Task.detached(priority: .userInitiated) { [resolvedCdnSelection] in
                try CoreClient.shared.livePlayUrl(roomID: route.roomID, cdn: resolvedCdnSelection)
            }.value
            configurePlayer(with: play, roomID: route.roomID)
        } catch {
            errorText = (error as NSError).localizedDescription
        }
        isLoading = false
    }

    func switchQuality(to qn: Int64, cdnSelection: String? = nil) async {
        guard roomID > 0, qn != currentQn else { return }
        let resolvedCdnSelection = cdnSelection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? self.cdnSelection
        self.cdnSelection = resolvedCdnSelection
        isLoading = true
        errorText = nil
        do {
            let play = try await Task.detached(priority: .userInitiated) { [roomID, resolvedCdnSelection] in
                try CoreClient.shared.livePlayUrl(roomID: roomID, qn: qn, cdn: resolvedCdnSelection)
            }.value
            configurePlayer(with: play, roomID: roomID)
        } catch {
            errorText = (error as NSError).localizedDescription
        }
        isLoading = false
    }

    func teardown() {
        stopCurrentPlayer(releaseAudioSession: true)
    }

    func activatePlayback() {
        guard let player else { return }
        PlayerAudioSessionCoordinator.shared.setSessionNeeded(true, by: self)
        player.play()
    }

    func suspendPlayback() {
        player?.pause()
        PlayerAudioSessionCoordinator.shared.setSessionNeeded(false, by: self)
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
        let previousPlayer = player
        playerTimeControlObservation?.invalidate()
        player = nextPlayer
        observePlayer(nextPlayer)
        currentQn = play.quality
        availableQualities = play.acceptQuality
        PlayerAudioSessionCoordinator.shared.setSessionNeeded(true, by: self)
        previousPlayer?.pause()
        previousPlayer?.replaceCurrentItem(with: nil)
        nextPlayer.play()
    }

    private func stopCurrentPlayer(releaseAudioSession: Bool) {
        playerTimeControlObservation?.invalidate()
        playerTimeControlObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if releaseAudioSession {
            PlayerAudioSessionCoordinator.shared.setSessionNeeded(false, by: self)
        }
    }

    private func observePlayer(_ observedPlayer: AVPlayer) {
        playerTimeControlObservation = observedPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self, weak observedPlayer] player, _ in
            Task { @MainActor in
                guard let self,
                      let observedPlayer,
                      self.player === observedPlayer else { return }
                PlayerAudioSessionCoordinator.shared.setSessionNeeded(player.timeControlStatus != .paused, by: self)
            }
        }
    }
}

struct LiveRoomView: View {
    let route: DeepLinkRouter.LiveRoute

    @StateObject private var vm: LiveRoomViewModel
    @State private var danmaku = DanmakuController()
    @State private var danmakuStream: LiveDanmakuStream?
    @State private var danmakuEnabled = true
    @State private var showDanmakuSheet = false
    @State private var danmakuMessages: [LiveDanmakuMessageDTO] = []
    @State private var loadedDanmakuListRoomID: Int64 = 0
    @State private var isFullscreen = false
    @EnvironmentObject private var router: DeepLinkRouter
    @EnvironmentObject private var settings: AppSettings

    init(route: DeepLinkRouter.LiveRoute, vm: LiveRoomViewModel? = nil) {
        self.route = route
        _vm = StateObject(wrappedValue: vm ?? LiveRoomViewModel(sessionID: route.id))
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
                    liveDanmakuList
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
            if !isFullscreen {
                ToolbarItem(placement: .topBarTrailing) {
                    PlayerToolbarDanmaku(
                        danmakuEnabled: $danmakuEnabled,
                        isEnabled: vm.player != nil,
                        onLongPress: { showDanmakuSheet = true }
                    )
                }
                if !vm.availableQualities.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        qualityMenu
                    }
                }
            }
        }
        .task(id: route.roomID) {
            await vm.load(route: route, cdnSelection: settings.cdnService.rawValue)
        }
        .onChange(of: vm.player) { newPlayer in
            if let newPlayer {
                danmaku.attach(newPlayer)
                startDanmakuStreamIfNeeded()
            }
        }
        .onAppear {
            if let player = vm.player {
                danmaku.attach(player)
                startDanmakuStreamIfNeeded()
                vm.activatePlayback()
            } else {
                Task { await vm.load(route: route, cdnSelection: settings.cdnService.rawValue) }
            }
        }
        .onDisappear {
            guard !isFullscreen else { return }
            danmaku.detach()
            danmakuStream?.close()
            danmakuStream = nil
            vm.suspendPlayback()
        }
        .sheet(isPresented: $showDanmakuSheet) {
            LiveDanmakuSendSheet(roomID: route.roomID)
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
                    danmakuEnabled: danmakuEnabled,
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

    private func startDanmakuStreamIfNeeded() {
        guard vm.player != nil, danmakuStream == nil else { return }
        let selfMID = CoreClient.shared.sessionSnapshot().mid
        let stream = LiveDanmakuStream(roomID: route.roomID, selfMID: selfMID) { item, message in
            danmaku.appendLive(item)
            appendDanmakuMessage(message)
        }
        danmakuStream = stream
        Task {
            await loadDanmakuListIfNeeded()
            await stream.start()
        }
    }

    private func loadDanmakuListIfNeeded() async {
        guard loadedDanmakuListRoomID != route.roomID else { return }
        loadedDanmakuListRoomID = route.roomID
        do {
            let items = try await Task.detached(priority: .utility) { [roomID = route.roomID] in
                try CoreClient.shared.liveDanmakuHistory(roomID: roomID)
                    .items
            }.value
            guard !items.isEmpty else { return }
            appendDanmakuMessages(items)
        } catch {
            AppLog.error("live", "直播历史弹幕加载失败", error: error, metadata: [
                "roomID": String(route.roomID)
            ])
        }
    }

    private func appendDanmakuMessage(_ message: LiveDanmakuMessageDTO) {
        appendDanmakuMessages([message])
    }

    private func appendDanmakuMessages(_ incoming: [LiveDanmakuMessageDTO]) {
        guard !incoming.isEmpty else { return }
        var seen = Set(danmakuMessages.map(\.id))
        var next = danmakuMessages
        for message in incoming where !message.text.isEmpty && seen.insert(message.id).inserted {
            next.append(message)
        }
        if next.count > 1_000 {
            next.removeFirst(next.count - 1_000)
        }
        danmakuMessages = next
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

    private var liveDanmakuList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IbiliTheme.accent)
                Text("弹幕")
                    .font(.headline)
                    .foregroundStyle(IbiliTheme.textPrimary)
                Spacer(minLength: 0)
                if !danmakuMessages.isEmpty {
                    Text("\(danmakuMessages.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
            }

            if danmakuMessages.isEmpty {
                Text(vm.player == nil && vm.errorText == nil ? "直播加载后会显示弹幕" : "暂无弹幕")
                    .font(.subheadline)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 280, alignment: .center)
            } else {
                LiveDanmakuScrollPane(messages: danmakuMessages)
            }
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
                    Task { await vm.switchQuality(to: quality.qn, cdnSelection: settings.cdnService.rawValue) }
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
        .tint(IbiliTheme.accent)
        .accessibilityLabel("直播清晰度")
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

private struct LiveDanmakuScrollPane: View {
    let messages: [LiveDanmakuMessageDTO]

    @State private var followsLatest = true
    @State private var showsJumpToBottom = false
    @State private var pendingScrollWork: DispatchWorkItem?

    private static let bottomID = "live-danmaku-bottom"
    private let panelHeight: CGFloat = 300

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(messages) { message in
                            LiveDanmakuMessageRow(message: message)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                    }
                    .padding(.vertical, 2)
                    .background(
                        LiveDanmakuScrollObserver(
                            followsLatest: $followsLatest,
                            showsJumpToBottom: $showsJumpToBottom
                        )
                    )
                }
                .frame(height: panelHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onAppear {
                    scheduleScrollToBottom(proxy, animated: false)
                }
                .onChange(of: messages.count) { _ in
                    if followsLatest {
                        scheduleScrollToBottom(proxy, animated: false)
                    } else {
                        showsJumpToBottom = true
                    }
                }

                if showsJumpToBottom {
                    Button {
                        followsLatest = true
                        showsJumpToBottom = false
                        scheduleScrollToBottom(proxy)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(IbiliTheme.accent))
                            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .accessibilityLabel("回到最新弹幕")
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: showsJumpToBottom)
    }

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        pendingScrollWork?.cancel()
        let work = DispatchWorkItem {
            let updates = {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            if animated {
                withAnimation(.easeOut(duration: 0.18), updates)
            } else {
                updates()
            }
        }
        pendingScrollWork = work
        if animated {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
        }
    }
}

private struct LiveDanmakuScrollObserver: UIViewRepresentable {
    @Binding var followsLatest: Bool
    @Binding var showsJumpToBottom: Bool

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onResolve = { scrollView in
            context.coordinator.attach(to: scrollView)
        }
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        context.coordinator.parent = self
        uiView.onResolve = { scrollView in
            context.coordinator.attach(to: scrollView)
        }
        uiView.resolve()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator {
        var parent: LiveDanmakuScrollObserver
        private weak var scrollView: UIScrollView?
        private var contentOffsetObservation: NSKeyValueObservation?

        init(parent: LiveDanmakuScrollObserver) {
            self.parent = parent
        }

        func attach(to scrollView: UIScrollView?) {
            guard self.scrollView !== scrollView else { return }
            contentOffsetObservation?.invalidate()
            self.scrollView = scrollView
            guard let scrollView else { return }
            contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self, weak scrollView] _, _ in
                guard let self, let scrollView else { return }
                DispatchQueue.main.async {
                    self.updateState(from: scrollView)
                }
            }
        }

        private func updateState(from scrollView: UIScrollView) {
            let distanceToBottom = scrollView.contentSize.height
                + scrollView.adjustedContentInset.bottom
                - scrollView.bounds.height
                - scrollView.contentOffset.y
            let isAtBottom = distanceToBottom <= 36
            let isUserMoving = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating

            if isAtBottom {
                parent.followsLatest = true
                parent.showsJumpToBottom = false
            } else if isUserMoving {
                parent.followsLatest = false
                parent.showsJumpToBottom = true
            }
        }
    }

    final class ObserverView: UIView {
        var onResolve: ((UIScrollView?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolve()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            resolve()
        }

        func resolve() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onResolve?(self.enclosingScrollView())
            }
        }

        private func enclosingScrollView() -> UIScrollView? {
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView {
                    return scrollView
                }
                view = current.superview
            }
            return nil
        }
    }
}

private struct LiveDanmakuMessageRow: View {
    let message: LiveDanmakuMessageDTO

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(message.isSelf ? IbiliTheme.accent : IbiliTheme.textSecondary)
                .lineLimit(1)
            Text(message.text)
                .font(.subheadline)
                .foregroundStyle(IbiliTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Capsule()
                .fill(message.isSelf ? IbiliTheme.accent.opacity(0.10) : Color.white.opacity(0.05))
        )
    }

    private var displayName: String {
        let trimmed = message.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "观众:" : "\(trimmed):"
    }
}
