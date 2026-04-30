import SwiftUI

/// The richer detail content area below the player. Owns its own
/// `VideoDetailViewModel` and the interaction service. Designed to
/// scroll independently below the fixed-height player.
///
/// Layout:
/// 1. Intro (title + stat line)
/// 2. Action row (like / coin / fav / share / watch later)
/// 3. Uploader card
/// 4. Description (expandable)
/// 5. UGC season card / pages picker (when applicable)
/// 6. Tags
/// 7. Segmented tabs: 简介 / 评论 / 相关
struct VideoDetailContent: View {
    let item: FeedItemDTO

    @StateObject private var vm = VideoDetailViewModel()
    @StateObject private var interaction = VideoInteractionService()
    @EnvironmentObject private var router: DeepLinkRouter
    @State private var tab: Tab = .intro
    @State private var toastWork: DispatchWorkItem?
    @State private var toast: String?

    enum Tab: String, CaseIterable, Identifiable {
        case intro = "简介"
        case replies = "评论"
        case related = "相关"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                Group {
                    switch tab {
                    case .intro:
                        introBody
                    case .replies:
                        CommentListView(oid: item.aid)
                            .padding(.horizontal, 16)
                    case .related:
                        RelatedVideoList(
                            items: vm.related,
                            isLoadingMore: vm.isLoadingMoreRelated,
                            isEnd: vm.relatedIsEnd,
                            onTap: { feedItem in
                                router.pending = feedItem
                            },
                            onReachEnd: {
                                Task { await vm.loadMoreRelated() }
                            }
                        )
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.bottom, 24)
            }
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .background(IbiliTheme.background)
        .task(id: "\(item.aid):\(item.bvid)") {
            interaction.reset(stat: vm.view?.stat ?? VideoStatDTO(view: 0, danmaku: 0, reply: 0, favorite: 0, coin: 0, share: 0, like: 0))
            // Run detail (view info) and relation hydrate concurrently.
            // The hydrate call only needs aid+bvid which are already
            // known from the feed item, so it doesn't have to wait for
            // the heavier `view` payload to come back. Saves ~1 RTT
            // off the total time-to-correct-button-state.
            if item.aid > 0 || !item.bvid.isEmpty {
                async let bootstrapTask: Void = vm.bootstrap(aid: item.aid, bvid: item.bvid)
                async let hydrateTask: Void = interaction.hydrate(aid: item.aid, bvid: item.bvid, ownerMid: nil)
                _ = await (bootstrapTask, hydrateTask)
            } else {
                await vm.bootstrap(aid: item.aid, bvid: item.bvid)
            }
            if let stat = vm.view?.stat { interaction.reset(stat: stat) }
        }
        .onChange(of: interaction.lastToast) { newToast in
            guard let m = newToast, !m.isEmpty else { return }
            toast = m
            toastWork?.cancel()
            let w = DispatchWorkItem { toast = nil }
            toastWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: w)
        }
        .overlay(alignment: .top) {
            if let m = toast {
                Text(m)
                    .font(.footnote)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(.regularMaterial))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    @ViewBuilder
    private var introBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            VideoIntroSection(
                title: vm.view?.title ?? item.title,
                stat: vm.view?.stat,
                pubdate: vm.view?.pubdate ?? 0,
                aid: vm.view?.aid ?? item.aid,
                bvid: vm.view?.bvid ?? item.bvid
            )
            .padding(.horizontal, 16)

            if let stat = vm.view?.stat {
                if interaction.isHydrating {
                    // Don't flash default-false icons before relation
                    // state arrives — show a spacer-height loader.
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .frame(height: 64)
                } else {
                    VideoActionRow(
                        aid: vm.view?.aid ?? item.aid,
                        bvid: vm.view?.bvid ?? item.bvid,
                        title: vm.view?.title ?? item.title,
                        stat: stat,
                        interaction: interaction
                    )
                    .padding(.horizontal, 8)
                }
            }

            if let owner = vm.view?.owner {
                UploaderCardView(owner: owner, interaction: interaction)
                    .padding(.horizontal, 16)
            }

            if let v = vm.view, !v.desc.isEmpty || !v.descV2.isEmpty {
                VideoDescriptionView(desc: v.desc, descV2: v.descV2)
                    .padding(.horizontal, 16)
            }

            if let v = vm.view {
                if let season = v.ugcSeason, season.id > 0 {
                    VideoSeasonCard(source: .season(season, currentCid: item.cid)) { aid, bvid, _ in
                        if let bvid {
                            Task { await vm.bootstrap(aid: aid ?? 0, bvid: bvid) }
                        }
                    }
                    .padding(.horizontal, 16)
                } else if v.pages.count > 1 {
                    VideoSeasonCard(source: .pages(v.pages, currentCid: item.cid)) { _, _, _ in }
                        .padding(.horizontal, 16)
                }
            }

            if let tags = vm.view?.tags, !tags.isEmpty {
                VideoTagsView(tags: tags)
                    .padding(.horizontal, 16)
            }

            if vm.isLoading, vm.view == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 30)
            } else if let err = vm.errorText, vm.view == nil {
                emptyState(title: "详情加载失败", symbol: "exclamationmark.triangle", message: err)
                    .padding(.vertical, 20)
            }
        }
    }

    @ViewBuilder
    private var introTabBody: some View {
        if vm.isLoading, vm.view == nil {
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, 30)
        } else if let err = vm.errorText, vm.view == nil {
            emptyState(title: "详情加载失败", symbol: "exclamationmark.triangle", message: err)
                .padding(.vertical, 20)
        } else {
            EmptyView()
        }
    }
}
