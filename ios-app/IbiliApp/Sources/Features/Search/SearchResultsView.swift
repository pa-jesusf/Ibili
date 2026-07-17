import SwiftUI
import UIKit

/// Grid of search-result cards. Reuses the same column-sizing logic as
/// the home feed so user preferences flow through, but disables the
/// home's top-trailing duration variant since search cards already
/// include a denser bottom info area.
struct SearchResultsView: View {
    @ObservedObject var vm: SearchViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var pageInputText: String = ""
    @State private var isPageInputPresented: Bool = false
    @State private var scrollToTopSignal = 0
    @State private var resolvingPgcSeasonID: Int64?
    @State private var toast: String?
    @State private var toastWork: DispatchWorkItem?
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation
    @Environment(\.prefersSplitRootSelection) private var prefersSplitRootSelection
    @Environment(\.splitFeedColumnLimit) private var splitFeedColumnLimit
    @Environment(\.rootContentNavigation) private var rootNavigation

    var body: some View {
        Group {
            if vm.results.isEmpty && vm.isLoading {
                Color.clear
            } else if let err = vm.errorText, vm.results.isEmpty {
                emptyState(systemImage: "wifi.exclamationmark", text: err, retry: true)
            } else if !vm.selectedType.isImplemented {
                emptyState(systemImage: "hourglass", text: "「\(vm.selectedType.label)」搜索敬请期待")
            } else if vm.results.isEmpty {
                emptyState(systemImage: "magnifyingglass", text: "暂无相关结果")
            } else {
                resultsGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(IbiliTheme.background)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.72)))
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: toast)
    }

    private var resultsGrid: some View {
        GeometryReader { geo in
            let preferredCols = settings.effectiveColumns(horizontal: hSizeClass, width: geo.size.width)
            let feedCols = splitFeedColumnLimit.map { min(preferredCols, $0) } ?? preferredCols
            let cols = vm.selectedType == .user
                ? (geo.size.width >= 760 ? 2 : 1)
                : (vm.selectedType == .bangumi || vm.selectedType == .movie ? 1 : feedCols)
            let hPad: CGFloat = 12
            let spacing: CGFloat = 12
            VirtualizedCollectionSurface(
                items: vm.results,
                layout: .grid(
                    columns: cols,
                    horizontalInset: hPad,
                    topInset: 8,
                    bottomInset: 8,
                    interitemSpacing: spacing,
                    rowSpacing: 14,
                    height: .estimated(vm.selectedType == .user ? 132 : 280)
                ),
                header: searchResultsHeader,
                footer: { AnyView(searchPaginationBar.padding(.horizontal, hPad).padding(.bottom, 20)) },
                scrollToTopSignal: scrollToTopSignal,
                prefetchThreshold: 8,
                onPrefetch: { items, width in
                    prefetchCovers(items, cardWidth: width)
                },
                splitTransitionIdentity: searchSplitTransitionIdentity
            ) { item, width in
                AnyView(resultButton(for: item, cardWidth: width))
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .modifier(ProMotionScrollHint())
        }
        .alert("跳转到页码", isPresented: $isPageInputPresented) {
            TextField("页码", text: $pageInputText)
                .keyboardType(.numberPad)
            Button("跳转") {
                if let target = Int64(pageInputText), target >= 1 {
                    vm.loadPage(target)
                    scrollToTopSignal += 1
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var searchPaginationBar: some View {
        HStack(spacing: 12) {
            Button {
                vm.loadPreviousPage()
                scrollToTopSignal += 1
            } label: {
                Label("上一页", systemImage: "chevron.left")
            }
            .disabled(vm.page <= 1)

            Spacer(minLength: 8)

            Button {
                pageInputText = String(max(vm.page, 1))
                isPageInputPresented = true
            } label: {
                VStack(spacing: 2) {
                    Text("第 \(max(vm.page, 1)) 页")
                        .font(.subheadline.weight(.semibold))
                    if vm.totalResults > 0 {
                        Text("约 \(BiliFormat.compactCount(vm.totalResults)) 个结果")
                            .font(.caption)
                            .foregroundStyle(IbiliTheme.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Button {
                vm.loadNextPage()
                scrollToTopSignal += 1
            } label: {
                Label("下一页", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!vm.hasMore)
        }
        .buttonStyle(.bordered)
        .tint(IbiliTheme.accent)
        .padding(.top, 8)
        .disabled(vm.isLoading)
    }

    @ViewBuilder
    private func resultButton(for item: SearchResultItem, cardWidth: CGFloat) -> some View {
        switch item {
        case .video(let video):
            ZStack(alignment: .bottomTrailing) {
                Button {
                    let item = feedItem(from: video)
                    if isInPlayerHostNavigation {
                        router.open(item)
                    } else if prefersSplitRootSelection {
                        router.select(item)
                    } else {
                        rootNavigation.openPlayer(item)
                    }
                } label: {
                    SearchResultCardView(
                        item: video,
                        cardWidth: cardWidth,
                        imageQuality: settings.resolvedImageQuality(),
                        meta: settings.searchCardMeta
                    )
                }
                .buttonStyle(.plain)

                VideoCardOverflowMenu(
                    bvid: video.bvid,
                    author: video.author,
                    ownerMID: video.ownerMID,
                    dislikeReasons: [],
                    feedbackReasons: [],
                    onCopyBVID: { copyBVID(video.bvid) },
                    onWatchLater: { addWatchLater(aid: video.aid) },
                    onVisitOwner: { openUserSpace(mid: video.ownerMID) },
                    onPlainDislike: { markNotInterested(aid: video.aid) },
                    onUndoDislike: { undoNotInterested(aid: video.aid) },
                    onDislikeReason: { _ in markNotInterested(aid: video.aid) },
                    onFeedbackReason: { _ in markNotInterested(aid: video.aid) },
                    onBlockOwner: { blockOwner(mid: video.ownerMID, author: video.author) }
                )
                .padding(.trailing, 4)
                .padding(.bottom, 4)
            }
            .frame(width: cardWidth, alignment: .topLeading)
        case .live(let live):
            Button {
                if isInPlayerHostNavigation {
                    router.openLive(roomID: live.roomID, title: live.title, cover: live.cover, anchorName: live.uname)
                } else if prefersSplitRootSelection {
                    router.selectLive(roomID: live.roomID, title: live.title, cover: live.cover, anchorName: live.uname)
                } else {
                    rootNavigation.openLive(roomID: live.roomID, title: live.title, cover: live.cover, anchorName: live.uname)
                }
            } label: {
                SearchLiveResultCardView(
                    item: live,
                    cardWidth: cardWidth,
                    imageQuality: settings.resolvedImageQuality()
                )
            }
            .buttonStyle(.plain)
        case .user(let user):
            Button {
                openUserSpace(mid: user.mid)
            } label: {
                SearchUserResultCardView(item: user, cardWidth: cardWidth)
            }
            .buttonStyle(.plain)
        case .article(let article):
            Button {
                if isInPlayerHostNavigation {
                    router.openArticle(id: String(article.id), kind: "read")
                } else if prefersSplitRootSelection {
                    router.selectArticle(id: String(article.id), kind: "read")
                } else {
                    rootNavigation.openArticle(id: String(article.id), kind: "read")
                }
            } label: {
                SearchArticleResultCardView(
                    item: article,
                    cardWidth: cardWidth,
                    imageQuality: settings.resolvedImageQuality()
                )
            }
            .buttonStyle(.plain)
        case .pgc(let pgc):
            Button {
                openPgc(pgc)
            } label: {
                ZStack {
                    SearchPgcResultCardView(
                        item: pgc,
                        cardWidth: cardWidth,
                        imageQuality: settings.resolvedImageQuality()
                    )
                    if resolvingPgcSeasonID == pgc.seasonID {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.black.opacity(0.18))
                        ProgressView().tint(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(resolvingPgcSeasonID == pgc.seasonID)
        }
    }

    private var searchResultsHeader: (() -> AnyView)? {
        guard vm.totalResults > 0 else { return nil }
        return {
            AnyView(
                HStack {
                    Text("约 \(BiliFormat.compactCount(vm.totalResults)) 个结果")
                        .font(.footnote)
                        .foregroundStyle(IbiliTheme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
            )
        }
    }

    private func prefetchCovers(_ items: [SearchResultItem], cardWidth: CGFloat) {
        let covers = items.map { result in
            switch result {
            case .video(let video): return video.cover
            case .live(let live): return live.cover
            case .user(let user): return user.face
            case .article(let article): return article.cover
            case .pgc(let pgc): return pgc.cover
            }
        }
        guard !covers.isEmpty else { return }
        let size = CGSize(width: cardWidth, height: (cardWidth / VideoCoverView.aspectRatio).rounded())
        CoverImagePrefetcher.shared.prefetch(covers,
                                             targetPointSize: size,
                                             quality: settings.resolvedImageQuality())
    }

    private func searchSplitTransitionIdentity(_ item: SearchResultItem) -> FeedStableIdentity? {
        switch item {
        case .video(let video):
            let identity = FeedStableIdentity(video)
            return identity.isValid ? identity : nil
        case .live(let live):
            return live.roomID > 0 ? FeedStableIdentity(roomID: live.roomID) : nil
        case .user, .article, .pgc:
            return nil
        }
    }

    private func emptyState(
        systemImage: String,
        text: String,
        retry: Bool = false
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(IbiliTheme.textSecondary)
            if retry {
                Button("重试") { vm.resubmitSubmittedQuery() }
                    .buttonStyle(.borderedProminent)
                    .tint(IbiliTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private func feedItem(from result: SearchVideoItemDTO) -> FeedItemDTO {
        FeedItemDTO(
            aid: result.aid,
            bvid: result.bvid,
            cid: result.cid,
            title: result.title,
            cover: result.cover,
            author: result.author,
            durationSec: result.durationSec,
            play: result.play,
            danmaku: result.danmaku,
            pubdate: result.pubdate,
            ownerMID: result.ownerMID
        )
    }

    private func copyBVID(_ bvid: String) {
        let value = bvid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            showToast("此视频暂无 BV 号")
            return
        }
        UIPasteboard.general.string = value
        showToast("已复制 BV 号")
    }

    private func addWatchLater(aid: Int64) {
        guard aid > 0 else { return }
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.watchLaterAdd(aid: aid)
                }.value
                showToast("已添加稍后再看")
            } catch {
                showToast("稍后再看失败")
                AppLog.error("search", "卡片菜单添加稍后再看失败", error: error, metadata: [
                    "aid": String(aid),
                ])
            }
        }
    }

    private func markNotInterested(aid: Int64) {
        guard aid > 0 else { return }
        vm.hideVideo(aid: aid)
        showToast("已减少此类结果")
        Task.detached(priority: .utility) {
            do {
                try CoreClient.shared.archiveDislike(aid: aid)
            } catch {
                AppLog.error("search", "卡片菜单不感兴趣同步失败", error: error, metadata: [
                    "aid": String(aid),
                ])
            }
        }
    }

    private func undoNotInterested(aid: Int64) {
        guard aid > 0 else { return }
        Task { @MainActor in
            do {
                try await Task.detached(priority: .utility) {
                    try CoreClient.shared.archiveDislike(aid: aid, dislike: false)
                }.value
                showToast("已撤销")
            } catch {
                showToast("撤销失败")
                AppLog.error("search", "卡片菜单撤销不感兴趣失败", error: error, metadata: [
                    "aid": String(aid),
                ])
            }
        }
    }

    private func blockOwner(mid: Int64, author: String) {
        guard mid > 0 else {
            showToast("无法识别 UP 主")
            return
        }
        let owner = author.trimmingCharacters(in: .whitespacesAndNewlines)
        vm.hideVideos(fromOwner: mid)
        showToast("已从当前结果隐藏")
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.relationModify(fid: mid, act: 5)
                }.value
                showToast(owner.isEmpty ? "已拉黑 UP 主" : "已拉黑 \(owner)")
            } catch {
                showToast("拉黑失败")
                AppLog.error("search", "卡片菜单拉黑失败", error: error, metadata: [
                    "mid": String(mid),
                ])
            }
        }
    }

    private func showToast(_ message: String) {
        toast = message
        toastWork?.cancel()
        let work = DispatchWorkItem { toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func openPgc(_ item: SearchPgcItemDTO) {
        guard resolvingPgcSeasonID == nil else { return }
        resolvingPgcSeasonID = item.seasonID
        Task {
            do {
                let season = try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.pgcSeason(seasonID: item.seasonID)
                }.value
                guard let episode = season.episodes.first else {
                    await MainActor.run { resolvingPgcSeasonID = nil }
                    return
                }
                let feedItem = FeedItemDTO(
                    aid: episode.aid,
                    bvid: episode.bvid,
                    cid: episode.cid,
                    title: pgcDisplayTitle(season: season, episode: episode),
                    cover: episode.cover.isEmpty ? season.cover : episode.cover,
                    author: season.upName,
                    durationSec: episode.durationSec,
                    play: season.stat.view,
                    danmaku: season.stat.danmaku,
                    epID: episode.epID,
                    seasonID: season.seasonID,
                    isPGC: true,
                    ownerMID: season.upMID
                )
                await MainActor.run {
                    resolvingPgcSeasonID = nil
                    if isInPlayerHostNavigation {
                        router.open(feedItem)
                    } else if prefersSplitRootSelection {
                        router.select(feedItem)
                    } else {
                        rootNavigation.openPlayer(feedItem)
                    }
                }
            } catch {
                await MainActor.run {
                    resolvingPgcSeasonID = nil
                }
                AppLog.error("search", "番剧/影视解析失败", error: error, metadata: [
                    "seasonID": String(item.seasonID),
                ])
            }
        }
    }

    private func pgcDisplayTitle(season: PgcSeasonDTO, episode: PgcEpisodeDTO) -> String {
        let seasonTitle = season.seasonTitle.isEmpty ? season.title : season.seasonTitle
        let epTitle = episode.longTitle.isEmpty ? episode.title : episode.longTitle
        guard !seasonTitle.isEmpty, !epTitle.isEmpty else {
            return seasonTitle.isEmpty ? epTitle : seasonTitle
        }
        return "\(seasonTitle) · \(epTitle)"
    }

    private func openUserSpace(mid: Int64) {
        guard mid > 0 else { return }
        if isInPlayerHostNavigation {
            router.openUserSpace(mid: mid)
        } else if prefersSplitRootSelection {
            router.selectUserSpace(mid: mid)
        } else {
            rootNavigation.openUserSpace(mid: mid)
        }
    }
}
