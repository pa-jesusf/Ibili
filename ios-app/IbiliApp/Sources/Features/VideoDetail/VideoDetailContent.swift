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

    /// Last reported Y of the in-content `DetailTabBar` (in the
    /// ScrollView's coordinate space). When this drops below 0 the
    /// picker has scrolled above the viewport.
    @State private var tabBarY: CGFloat = .greatestFiniteMagnitude
    @State private var lastTabBarY: CGFloat = .greatestFiniteMagnitude
    /// Whether the floating top picker is on screen. Driven by direction
    /// detection so the bar appears as soon as the user starts scrolling
    /// up, regardless of how far down they currently are.
    @State private var floatingTabsVisible: Bool = false

    enum Tab: String, CaseIterable, Identifiable {
        case intro = "简介"
        case replies = "评论"
        case related = "相关"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Anchor target for "scroll back to the top" when the
                    // user taps the segmented control's already-selected
                    // segment. Sits just above the picker so the picker
                    // ends up flush with the navigation bar.
                    Color.clear.frame(height: 0).id("tabBarTop")

                    DetailTabBar(selection: $tab) { tapped in
                        // Tap on already-selected segment ⇒ scroll back
                        // up to the top of the tab content.
                        if tapped == tab {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo("tabBarTop", anchor: .top)
                            }
                        } else {
                            tab = tapped
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(
                        // Publish the picker's Y position in the ScrollView's
                        // coordinate space. Once the picker scrolls above
                        // the viewport top we know to start considering the
                        // floating overlay.
                        GeometryReader { g in
                            Color.clear.preference(
                                key: TabBarOffsetKey.self,
                                value: g.frame(in: .named("detailScroll")).minY
                            )
                        }
                    )

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
            .coordinateSpace(name: "detailScroll")
            .onPreferenceChange(TabBarOffsetKey.self) { y in
                handleScroll(y: y)
            }
            .scrollIndicators(.hidden)
            .background(IbiliTheme.background)
            // Floating tab bar that snaps in when the user scrolls back
            // up while the static picker is still off-screen. Hidden the
            // moment they start scrolling down again so it doesn't fight
            // the user's reading flow.
            .overlay(alignment: .top) {
                if floatingTabsVisible {
                    DetailTabBar(selection: $tab) { tapped in
                        if tapped == tab {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo("tabBarTop", anchor: .top)
                            }
                        } else {
                            tab = tapped
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
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
                    VideoSeasonCard(source: .season(season, currentCid: item.cid)) { aid, bvid, cid in
                        // Tapping any other episode in the 合集 should
                        // *replace* the player, mirroring how related-tap
                        // works. Hand off to the router so the cover host
                        // re-keys onto the new video and the previous
                        // player tears down (no 套娃 chain).
                        guard cid != item.cid else { return }
                        let next = FeedItemDTO(
                            aid: aid ?? 0,
                            bvid: bvid ?? "",
                            cid: cid,
                            title: "", cover: "", author: "",
                            durationSec: 0, play: 0, danmaku: 0
                        )
                        router.pending = next
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

    /// Drive the floating tab-bar visibility from the in-content
    /// picker's Y offset. We only show the floating bar when:
    ///   * the in-content picker is above the viewport (y < 0), and
    ///   * the user is scrolling *up* (delta > 0)
    /// The hysteresis keeps the bar stable: a tiny up-flick reveals it
    /// instantly (no need to scroll all the way back to the top), and a
    /// small wobble doesn't ping-pong the visibility.
    private func handleScroll(y: CGFloat) {
        // Skip the very first sample — `lastTabBarY` is sentinel-init.
        if lastTabBarY == .greatestFiniteMagnitude {
            lastTabBarY = y
            tabBarY = y
            return
        }
        let delta = y - lastTabBarY
        lastTabBarY = y
        tabBarY = y
        // Only consider transitions once the static picker has actually
        // scrolled off-screen. While it's still visible the floating
        // bar would just be redundant chrome.
        let pickerOffscreen = y < -4
        if !pickerOffscreen {
            if floatingTabsVisible {
                withAnimation(.easeOut(duration: 0.16)) { floatingTabsVisible = false }
            }
            return
        }
        // Tiny upward delta is enough — no need to scroll back to the
        // top. Hysteresis is asymmetric so the bar is eager to appear
        // and lazy to hide, which matches Apple's own collapsible bars.
        if delta > 0.5 {
            if !floatingTabsVisible {
                withAnimation(.easeOut(duration: 0.18)) { floatingTabsVisible = true }
            }
        } else if delta < -2.0 {
            if floatingTabsVisible {
                withAnimation(.easeOut(duration: 0.16)) { floatingTabsVisible = false }
            }
        }
    }
}

private struct TabBarOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Custom segmented control used for the 简介 / 评论 / 相关 picker.
///
/// We can't use `Picker(.segmented)` here because we need to detect
/// taps on the *already selected* segment (to scroll to top). The
/// callback is invoked for every tap, and the parent decides whether
/// to mutate `selection` or to scroll-to-top. The selected indicator
/// is animated with `matchedGeometryEffect` so it slides between
/// segments the way the system Picker does, and the container picks
/// up the iOS 26 liquid-glass material when available.
struct DetailTabBar: View {
    @Binding var selection: VideoDetailContent.Tab
    let onTap: (VideoDetailContent.Tab) -> Void
    @Namespace private var pillNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(VideoDetailContent.Tab.allCases) { t in
                Button {
                    onTap(t)
                } label: {
                    ZStack {
                        if selection == t {
                            Capsule(style: .continuous)
                                .fill(IbiliTheme.accent)
                                .matchedGeometryEffect(id: "selectedPill", in: pillNamespace)
                                .padding(2)
                        }
                        Text(t.rawValue)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(selection == t ? .white : IbiliTheme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(tabBarBackground)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: selection)
    }

    /// Liquid-glass capsule background. Falls back to `.regularMaterial`
    /// on pre-26 OS where `glassEffect` is unavailable, and finally to
    /// the surface tint on the oldest supported targets.
    @ViewBuilder
    private var tabBarBackground: some View {
        if #available(iOS 26.0, *) {
            Capsule(style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
        }
    }
}
