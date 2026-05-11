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
    @State private var scrollID: UUID = UUID()
    @State private var userSpaceMID: Int64?
    @State private var resolvingPgcSeasonID: Int64?
    @StateObject private var scrollContext = InterruptibleScrollContext()
    @Environment(\.isInPlayerHostNavigation) private var isInPlayerHostNavigation
    @Environment(\.prefersSplitRootSelection) private var prefersSplitRootSelection
    @Environment(\.splitFeedColumnLimit) private var splitFeedColumnLimit

    var body: some View {
        Group {
            if vm.results.isEmpty && vm.isLoading {
                ProgressView().tint(IbiliTheme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .background {
            if !isInPlayerHostNavigation {
                NavigationLink(
                    isActive: Binding(
                        get: { userSpaceMID != nil },
                        set: { if !$0 { userSpaceMID = nil } }
                    ),
                    destination: {
                        if let mid = userSpaceMID {
                            UserSpaceView(mid: mid)
                        }
                    },
                    label: { EmptyView() }
                )
                .opacity(0)
                .allowsHitTesting(false)
            }
        }
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
            let totalSpacing = spacing * CGFloat(cols - 1) + hPad * 2
            let cardW = max(1, floor((geo.size.width - totalSpacing) / CGFloat(cols)))
            let rowSpacing: CGFloat = 14
            let gridItems = Array(
                repeating: GridItem(.fixed(cardW), spacing: spacing, alignment: .top),
                count: cols
            )

            ScrollViewReader { scrollProxy in
                ScrollView {
                    InterruptibleScrollCapture(context: scrollContext)
                        .frame(width: 0, height: 0)
                    Color.clear.frame(height: 0).id("searchResultsTop")

                    if vm.totalResults > 0 {
                        HStack {
                            Text("约 \(BiliFormat.compactCount(vm.totalResults)) 个结果")
                                .font(.footnote)
                                .foregroundStyle(IbiliTheme.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, hPad)
                        .padding(.top, 4)
                    }

                    LazyVGrid(columns: gridItems, spacing: rowSpacing) {
                        ForEach(vm.results) { item in
                            resultButton(for: item, cardWidth: cardW)
                                .onAppear {
                                    prefetchCovers(around: item, cardWidth: cardW)
                                }
                        }
                    }
                    .padding(.horizontal, hPad)
                    .padding(.vertical, 8)

                    searchPaginationBar
                        .padding(.horizontal, hPad)
                        .padding(.bottom, 20)
                }
                .onChange(of: scrollID) { _ in
                    scrollProxy.interruptingScrollTo(
                        "searchResultsTop",
                        anchor: .top,
                        context: scrollContext,
                        animation: .easeOut(duration: 0.2)
                    )
                }
                .transaction { $0.animation = nil }
            }
        }
        .alert("跳转到页码", isPresented: $isPageInputPresented) {
            TextField("页码", text: $pageInputText)
                .keyboardType(.numberPad)
            Button("跳转") {
                if let target = Int64(pageInputText), target >= 1 {
                    vm.loadPage(target)
                    scrollID = UUID()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .modifier(ProMotionScrollHint())
    }

    @ViewBuilder
    private var searchPaginationBar: some View {
        if vm.isLoading && !vm.results.isEmpty {
            ProgressView().padding(.vertical, 16)
        } else {
            HStack(spacing: 12) {
                Button {
                    vm.loadPreviousPage()
                    scrollID = UUID()
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
                    scrollID = UUID()
                } label: {
                    Label("下一页", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!vm.hasMore)
            }
            .buttonStyle(.bordered)
            .tint(IbiliTheme.accent)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func resultButton(for item: SearchResultItem, cardWidth: CGFloat) -> some View {
        switch item {
        case .video(let video):
            Button {
                let item = feedItem(from: video)
                if prefersSplitRootSelection {
                    router.select(item)
                } else {
                    router.open(item)
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
        case .live(let live):
            Button {
                if prefersSplitRootSelection {
                    router.selectLive(roomID: live.roomID, title: live.title, cover: live.cover, anchorName: live.uname)
                } else {
                    router.openLive(roomID: live.roomID, title: live.title, cover: live.cover, anchorName: live.uname)
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
                if prefersSplitRootSelection {
                    router.selectArticle(id: String(article.id), kind: "read")
                } else {
                    router.openArticle(id: String(article.id), kind: "read")
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

    private func prefetchCovers(around item: SearchResultItem, cardWidth: CGFloat) {
        let lookahead = 18
        guard let idx = vm.results.firstIndex(where: { $0.id == item.id }) else { return }
        let start = min(idx + 1, vm.results.count)
        let end = min(start + lookahead, vm.results.count)
        guard start < end else { return }
        let covers = vm.results[start..<end].map { result in
            switch result {
            case .video(let video): return video.cover
            case .live(let live): return live.cover
            case .user(let user): return user.face
            case .article(let article): return article.cover
            case .pgc(let pgc): return pgc.cover
            }
        }
        let size = CGSize(width: cardWidth, height: (cardWidth / VideoCoverView.aspectRatio).rounded())
        CoverImagePrefetcher.shared.prefetch(covers,
                                             targetPointSize: size,
                                             quality: settings.resolvedImageQuality())
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
                Button("重试") { vm.submit() }
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
            pubdate: result.pubdate
        )
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
                    isPGC: true
                )
                await MainActor.run {
                    resolvingPgcSeasonID = nil
                    if prefersSplitRootSelection {
                        router.select(feedItem)
                    } else {
                        router.open(feedItem)
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
            userSpaceMID = mid
        }
    }
}
