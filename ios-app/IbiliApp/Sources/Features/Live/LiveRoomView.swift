import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class LiveRuntimeCoordinator {
    static let shared = LiveRuntimeCoordinator()
    private static let prepareGrace: TimeInterval = 0.28
    private static let teardownGrace: TimeInterval = 2.0

    private var viewModels: [PlayerSessionID: LiveRoomViewModel] = [:]
    private var pendingPreparationWork: [PlayerSessionID: DispatchWorkItem] = [:]
    private var pendingTeardownWork: [PlayerSessionID: DispatchWorkItem] = [:]
    private var pendingTeardownTokens: [PlayerSessionID: UUID] = [:]

    func viewModel(for routeID: PlayerSessionID) -> LiveRoomViewModel {
        cancelPendingTeardown(for: routeID)
        if let existing = viewModels[routeID] {
            return existing
        }
        let viewModel = LiveRoomViewModel(sessionID: routeID)
        viewModels[routeID] = viewModel
        return viewModel
    }

    func prepareForDismissal(routeID: PlayerSessionID) {
        guard let viewModel = viewModels[routeID] else { return }
        viewModel.prepareForDismissal()
    }

    func retainSessions(root: DeepLinkRouter.LiveRoute?, stack: [DeepLinkRouter.LiveRoute]) {
        let retainedIDs = Set(([root].compactMap { $0?.id }) + stack.map(\.id))
        for routeID in retainedIDs {
            cancelPendingTeardown(for: routeID)
        }
        let staleSessions = viewModels.filter { !retainedIDs.contains($0.key) }
        for (routeID, viewModel) in staleSessions {
            scheduleTeardown(for: routeID, viewModel: viewModel)
        }
    }

    private func cancelPendingTeardown(for routeID: PlayerSessionID) {
        pendingPreparationWork.removeValue(forKey: routeID)?.cancel()
        pendingTeardownWork.removeValue(forKey: routeID)?.cancel()
        pendingTeardownTokens.removeValue(forKey: routeID)
    }

    private func scheduleTeardown(for routeID: PlayerSessionID, viewModel: LiveRoomViewModel) {
        guard pendingTeardownWork[routeID] == nil else { return }
        let token = UUID()
        pendingTeardownTokens[routeID] = token
        let prepareWork = DispatchWorkItem { [weak self, weak viewModel] in
            Task { @MainActor [weak self, weak viewModel] in
                guard let self,
                      self.pendingTeardownTokens[routeID] == token else { return }
                self.pendingPreparationWork.removeValue(forKey: routeID)
                viewModel?.prepareForDismissal()
            }
        }
        pendingPreparationWork[routeID] = prepareWork
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.prepareGrace, execute: prepareWork)
        AppLog.debug("live", "延迟销毁直播会话", metadata: [
            "routeID": routeID.uuidString,
            "prepareDelayMs": String(Int(Self.prepareGrace * 1000)),
            "delayMs": String(Int(Self.teardownGrace * 1000)),
        ])
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.pendingTeardownTokens[routeID] == token else { return }
                self.pendingPreparationWork.removeValue(forKey: routeID)?.cancel()
                self.pendingTeardownWork.removeValue(forKey: routeID)
                self.pendingTeardownTokens.removeValue(forKey: routeID)
                guard let viewModel = self.viewModels[routeID] else { return }
                viewModel.teardown()
                self.viewModels.removeValue(forKey: routeID)
            }
        }
        pendingTeardownWork[routeID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.teardownGrace, execute: work)
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
    private var loadGeneration: UInt64 = 0
    private var isClosing = false
    private var dismissalFadeTask: Task<Void, Never>?

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
        guard !isClosing || roomID != route.roomID || player == nil else { return }
        isClosing = false
        dismissalFadeTask?.cancel()
        dismissalFadeTask = nil
        let resolvedCdnSelection = cdnSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard roomID != route.roomID || self.cdnSelection != resolvedCdnSelection || player == nil else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        roomID = route.roomID
        self.cdnSelection = resolvedCdnSelection
        isLoading = true
        errorText = nil
        stopCurrentPlayer(releaseAudioSession: true)

        let fetchedInfo: LiveRoomInfoDTO? = await Task.detached {
            try? CoreClient.shared.liveRoomInfo(roomID: route.roomID)
        }.value
        guard isCurrentLoad(generation, roomID: route.roomID) else { return }
        info = fetchedInfo

        do {
            let play = try await Task.detached(priority: .userInitiated) { [resolvedCdnSelection] in
                try CoreClient.shared.livePlayUrl(roomID: route.roomID, cdn: resolvedCdnSelection)
            }.value
            guard isCurrentLoad(generation, roomID: route.roomID) else { return }
            configurePlayer(with: play, roomID: route.roomID)
        } catch {
            guard isCurrentLoad(generation, roomID: route.roomID) else { return }
            errorText = (error as NSError).localizedDescription
        }
        if isCurrentLoad(generation, roomID: route.roomID) {
            isLoading = false
        }
    }

    func switchQuality(to qn: Int64, cdnSelection: String? = nil) async {
        guard !isClosing, roomID > 0, qn != currentQn else { return }
        let resolvedCdnSelection = cdnSelection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? self.cdnSelection
        loadGeneration &+= 1
        let generation = loadGeneration
        let targetRoomID = roomID
        self.cdnSelection = resolvedCdnSelection
        isLoading = true
        errorText = nil
        do {
            let play = try await Task.detached(priority: .userInitiated) { [roomID, resolvedCdnSelection] in
                try CoreClient.shared.livePlayUrl(roomID: roomID, qn: qn, cdn: resolvedCdnSelection)
            }.value
            guard isCurrentLoad(generation, roomID: targetRoomID) else { return }
            configurePlayer(with: play, roomID: targetRoomID)
        } catch {
            guard isCurrentLoad(generation, roomID: targetRoomID) else { return }
            errorText = (error as NSError).localizedDescription
        }
        if isCurrentLoad(generation, roomID: targetRoomID) {
            isLoading = false
        }
    }

    func teardown() {
        isClosing = true
        loadGeneration &+= 1
        dismissalFadeTask?.cancel()
        dismissalFadeTask = nil
        stopCurrentPlayer(releaseAudioSession: true)
    }

    func prepareForDismissal() {
        guard !isClosing else { return }
        isClosing = true
        loadGeneration &+= 1
        playerTimeControlObservation?.invalidate()
        playerTimeControlObservation = nil
        fadeOutAndPauseForDismissal()
    }

    func activatePlayback() {
        guard !isClosing, let player else { return }
        PlayerAudioSessionCoordinator.shared.setSessionNeeded(true, by: self)
        player.play()
    }

    func suspendPlayback() {
        guard !isClosing else { return }
        player?.pause()
        PlayerAudioSessionCoordinator.shared.setSessionNeeded(false, by: self)
    }

    var canRestorePlaybackAfterPresentation: Bool {
        !isClosing
    }

    private func configurePlayer(with play: LivePlayUrlDTO, roomID: Int64) {
        guard !isClosing else { return }
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
        nextPlayer.allowsExternalPlayback = true
        nextPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true
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
        dismissalFadeTask?.cancel()
        dismissalFadeTask = nil
        playerTimeControlObservation?.invalidate()
        playerTimeControlObservation = nil
        if let player {
            player.volume = 0
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        player = nil
        if releaseAudioSession {
            PlayerAudioSessionCoordinator.shared.setSessionNeeded(false, by: self)
        }
    }

    private func fadeOutAndPauseForDismissal() {
        dismissalFadeTask?.cancel()
        guard let player else {
            PlayerAudioSessionCoordinator.shared.setSessionNeeded(false, by: self)
            return
        }
        dismissalFadeTask = Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }
            let startVolume = player.volume
            let steps = 4
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: 18_000_000)
                guard !Task.isCancelled, self.player === player else { return }
                player.volume = startVolume * Float(steps - step) / Float(steps)
            }
            guard !Task.isCancelled, self.player === player else { return }
            player.pause()
            player.volume = 0
            PlayerAudioSessionCoordinator.shared.setSessionNeeded(false, by: self)
        }
    }

    private func observePlayer(_ observedPlayer: AVPlayer) {
        playerTimeControlObservation = observedPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self, weak observedPlayer] player, _ in
            Task { @MainActor in
                guard let self,
                      let observedPlayer,
                      !self.isClosing,
                      self.player === observedPlayer else { return }
                PlayerAudioSessionCoordinator.shared.setSessionNeeded(player.timeControlStatus != .paused, by: self)
            }
        }
    }

    private func isCurrentLoad(_ generation: UInt64, roomID: Int64) -> Bool {
        !isClosing && loadGeneration == generation && self.roomID == roomID
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
    @State private var loadingDanmakuHistoryRoomID: Int64 = 0
    @State private var isLoadingDanmakuHistory = false
    @State private var isFullscreen = false
    @State private var isInlineHostVisible = false
    @State private var lifecycleGeneration: UInt64 = 0
    @EnvironmentObject private var router: DeepLinkRouter
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation
    @Environment(\.inlinePlayerNavigation) private var inlinePlayerNavigation

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
            let generation = lifecycleGeneration
            async let historyTask: Void = loadDanmakuListIfNeeded(generation: generation)
            async let playerTask: Void = vm.load(route: route, cdnSelection: settings.cdnService.rawValue)
            _ = await (historyTask, playerTask)
        }
        .onChange(of: vm.player) { newPlayer in
            if let newPlayer {
                danmaku.attach(newPlayer)
                startDanmakuStreamIfNeeded()
            }
        }
        .onAppear {
            Orientation.activatePlayerPresentationRoute(vm.sessionID)
            isInlineHostVisible = true
            if let player = vm.player {
                danmaku.attach(player)
                startDanmakuStreamIfNeeded()
                vm.activatePlayback()
            } else {
                Task { await vm.load(route: route, cdnSelection: settings.cdnService.rawValue) }
            }
        }
        .onDisappear {
            isInlineHostVisible = false
            guard !isFullscreen else { return }
            Orientation.deactivatePlayerPresentationRoute(vm.sessionID)
            lifecycleGeneration &+= 1
            stopDanmakuPipeline()
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
                    isPresentationRouteActive: isPresentationRouteActive,
                    danmaku: danmaku,
                    subtitle: nil,
                    subtitleEnabled: false,
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
                    canRestorePlaybackAfterPresentation: { isPresentationRouteActive && vm.canRestorePlaybackAfterPresentation },
                    onCreated: { _ in },
                    onPresentationEvent: handlePresentationEvent
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
        let generation = lifecycleGeneration
        let selfMID = CoreClient.shared.sessionSnapshot().mid
        let stream = LiveDanmakuStream(roomID: route.roomID, selfMID: selfMID) { item, message in
            guard generation == lifecycleGeneration else { return }
            danmaku.appendLive(item)
            appendDanmakuMessage(message)
        }
        danmakuStream = stream
        Task {
            guard generation == lifecycleGeneration else { return }
            await loadDanmakuListIfNeeded(generation: generation)
        }
        Task {
            guard generation == lifecycleGeneration else { return }
            await stream.start()
        }
    }

    private func stopDanmakuPipeline() {
        danmaku.detach()
        danmaku.clear()
        danmakuStream?.close()
        danmakuStream = nil
        danmakuMessages.removeAll()
        loadedDanmakuListRoomID = 0
        loadingDanmakuHistoryRoomID = 0
        isLoadingDanmakuHistory = false
    }

    private func loadDanmakuListIfNeeded(generation: UInt64) async {
        let roomID = route.roomID
        guard loadedDanmakuListRoomID != roomID,
              loadingDanmakuHistoryRoomID != roomID else { return }
        loadingDanmakuHistoryRoomID = roomID
        isLoadingDanmakuHistory = true
        defer {
            if loadingDanmakuHistoryRoomID == roomID {
                loadingDanmakuHistoryRoomID = 0
                isLoadingDanmakuHistory = false
            }
        }
        do {
            let items = try await Task.detached(priority: .utility) { [roomID] in
                try CoreClient.shared.liveDanmakuHistory(roomID: roomID)
                    .items
            }.value
            guard generation == lifecycleGeneration, route.roomID == roomID else { return }
            loadedDanmakuListRoomID = roomID
            guard !items.isEmpty else { return }
            prependDanmakuHistoryMessages(items)
        } catch {
            guard generation == lifecycleGeneration else { return }
            AppLog.error("live", "直播历史弹幕加载失败", error: error, metadata: [
                "roomID": String(roomID)
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

    private func prependDanmakuHistoryMessages(_ incoming: [LiveDanmakuMessageDTO]) {
        guard !incoming.isEmpty else { return }
        var seen = Set<String>()
        var next: [LiveDanmakuMessageDTO] = []
        for message in incoming where !message.text.isEmpty && seen.insert(message.id).inserted {
            next.append(message)
        }
        for message in danmakuMessages where !message.text.isEmpty && seen.insert(message.id).inserted {
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
                if isInPlayerHostNavigation, let inlinePlayerNavigation {
                    inlinePlayerNavigation.openUser(mid: uid)
                } else {
                    router.openUserSpace(mid: uid)
                }
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
                Text(isLoadingDanmakuHistory ? "正在加载历史弹幕" : (vm.player == nil && vm.errorText == nil ? "直播加载后会显示弹幕" : "暂无弹幕"))
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

    private var isPresentationRouteActive: Bool {
        isInlineHostVisible || isFullscreen
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
            RichReplyText(message: message.text,
                          emotes: message.emotes,
                          jumpUrls: [],
                          font: .subheadline,
                          textColor: IbiliTheme.textPrimary)
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
