import SwiftUI
import UIKit

struct HomeView: View {
    @State private var section: HomeFeedSection = .recommend
    @State private var headerCollapseProgress: CGFloat = 0
    @StateObject private var recommendVM: HomeViewModel
    @StateObject private var hotVM: HomeViewModel
    @StateObject private var liveVM = LiveHomeViewModel()
    @StateObject private var prefetch = FeedPrefetchCoordinator()

    init() {
        _recommendVM = StateObject(wrappedValue: HomeViewModel(section: .recommend))
        _hotVM = StateObject(wrappedValue: HomeViewModel(section: .hot))
    }

    var body: some View {
        Group {
            switch section {
            case .recommend, .hot:
                HomeFeedPage(
                    section: $section,
                    collapseProgress: $headerCollapseProgress,
                    vm: activeViewModel,
                    prefetch: prefetch
                )
            case .live:
                HomeLiveFeedPage(
                    section: $section,
                    collapseProgress: $headerCollapseProgress,
                    vm: liveVM
                )
            }
        }
        .background(IbiliTheme.background.ignoresSafeArea())
        .overlay(alignment: .top) {
            FeedNavigationBackgroundOverlay(collapseProgress: headerCollapseProgress)
        }
        .overlay(alignment: .top) {
            FeedFloatingSegmentedControlOverlay(
                tabs: Array(HomeFeedSection.allCases),
                title: { $0.title },
                selection: $section,
                collapseProgress: headerCollapseProgress
            )
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var activeViewModel: HomeViewModel {
        switch section {
        case .recommend:
            return recommendVM
        case .hot, .live:
            return hotVM
        }
    }
}

private struct HomeFeedPage: View {
    @Binding var section: HomeFeedSection
    @Binding var collapseProgress: CGFloat
    @ObservedObject var vm: HomeViewModel
    let prefetch: FeedPrefetchCoordinator

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        feedGrid
        .task(id: vm.section) { await vm.loadInitial() }
        .refreshable { await vm.refresh() }
    }

    private var feedGrid: some View {
        GeometryReader { geo in
            let cols = settings.effectiveColumns(horizontal: hSizeClass, width: geo.size.width)
            let usesTopTrailingDuration = UIDevice.current.userInterfaceIdiom == .phone && cols >= 3
            let hPad: CGFloat = 12
            let spacing: CGFloat = 12
            let totalSpacing = spacing * CGFloat(cols - 1) + hPad * 2
            let cardW = max(1, floor((geo.size.width - totalSpacing) / CGFloat(cols)))
            let rowSpacing: CGFloat = 14
            let gridItems = Array(
                repeating: GridItem(.fixed(cardW), spacing: spacing, alignment: .top),
                count: cols
            )

            ScrollView {
                if #unavailable(iOS 18.0) {
                    ScrollHeaderOffsetReader(coordinateSpace: "home-feed-scroll")
                }

                FeedTitleHeader(
                    title: "主页",
                    collapseProgress: collapseProgress,
                    showsBackground: false
                )

                if vm.items.isEmpty && vm.isLoading {
                    ProgressView()
                        .tint(IbiliTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)
                } else if let err = vm.errorText, vm.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                        Text(err).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("重试") { Task { await vm.refresh() } }
                            .buttonStyle(.borderedProminent).tint(IbiliTheme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                } else {
                    LazyVGrid(columns: gridItems, spacing: rowSpacing) {
                        ForEach(vm.items) { item in
                            Button {
                                router.open(item)
                            } label: {
                                VideoCardView(
                                    item: item,
                                    cardWidth: cardW,
                                    imageQuality: settings.resolvedImageQuality(),
                                    showsDurationAtTopTrailing: usesTopTrailingDuration,
                                    meta: settings.homeCardMeta
                                )
                            }
                            .buttonStyle(TouchDownReportingButtonStyle {
                                prefetch.touchDown(item)
                            })
                            .onAppear {
                                prefetch.cardAppeared(item, allItems: vm.items)
                                prefetchCovers(around: item, cardWidth: cardW)
                                if !vm.isEnd, item.aid == vm.items.last?.aid {
                                    Task { await vm.loadMore() }
                                }
                            }
                            .onDisappear { prefetch.cardDisappeared(item) }
                        }
                    }
                    .padding(.horizontal, hPad)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                    if vm.isLoading && !vm.items.isEmpty {
                        ProgressView().padding()
                    } else if vm.isEnd, !vm.items.isEmpty {
                        Text("已经到底了")
                            .font(.caption)
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 18)
                    }
                }
            }
            .coordinateSpace(name: "home-feed-scroll")
            .modifier(ScrollOffsetCollapseDriver(progress: $collapseProgress))
            .modifier(ProMotionScrollHint())
            .onAppear {
                prefetch.update(preferredQn: Int64(settings.resolvedPreferredVideoQn()))
            }
        }
    }

    /// Pre-warm cover images ahead of the user's scroll position so
    /// cells already have their covers cached by the time they appear.
    private func prefetchCovers(around item: FeedItemDTO, cardWidth: CGFloat) {
        let lookahead = 18
        guard let idx = vm.items.firstIndex(where: { $0.aid == item.aid }) else { return }
        let start = min(idx + 1, vm.items.count)
        let end = min(start + lookahead, vm.items.count)
        guard start < end else { return }
        let covers = vm.items[start..<end].map(\.cover)
        let size = CGSize(width: cardWidth, height: (cardWidth / VideoCoverView.aspectRatio).rounded())
        CoverImagePrefetcher.shared.prefetch(covers,
                                             targetPointSize: size,
                                             quality: settings.resolvedImageQuality())
    }
}

private struct HomeLiveFeedPage: View {
    @Binding var section: HomeFeedSection
    @Binding var collapseProgress: CGFloat
    @ObservedObject var vm: LiveHomeViewModel

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        GeometryReader { geo in
            let cols = settings.effectiveColumns(horizontal: hSizeClass, width: geo.size.width)
            let hPad: CGFloat = 12
            let spacing: CGFloat = 12
            let totalSpacing = spacing * CGFloat(cols - 1) + hPad * 2
            let cardW = max(1, floor((geo.size.width - totalSpacing) / CGFloat(cols)))
            let rowSpacing: CGFloat = 14
            let gridItems = Array(
                repeating: GridItem(.fixed(cardW), spacing: spacing, alignment: .top),
                count: cols
            )

            ScrollView {
                if #unavailable(iOS 18.0) {
                    ScrollHeaderOffsetReader(coordinateSpace: "home-feed-scroll")
                }

                FeedTitleHeader(
                    title: "主页",
                    collapseProgress: collapseProgress,
                    showsBackground: false
                )

                if vm.items.isEmpty && vm.isLoading {
                    ProgressView()
                        .tint(IbiliTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)
                } else if let err = vm.errorText, vm.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                        Text(err).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("重试") { Task { await vm.refresh() } }
                            .buttonStyle(.borderedProminent).tint(IbiliTheme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                } else {
                    LazyVGrid(columns: gridItems, spacing: rowSpacing) {
                        ForEach(vm.items) { item in
                            Button {
                                router.openLive(
                                    roomID: item.roomID,
                                    title: item.title,
                                    cover: item.systemCover.isEmpty ? item.cover : item.systemCover,
                                    anchorName: item.uname
                                )
                            } label: {
                                LiveCardView(
                                    item: item,
                                    cardWidth: cardW,
                                    imageQuality: settings.resolvedImageQuality()
                                )
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                prefetchCovers(around: item, cardWidth: cardW)
                                if !vm.isEnd, item.roomID == vm.items.last?.roomID {
                                    Task { await vm.loadMore() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, hPad)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                    if vm.isLoading && !vm.items.isEmpty {
                        ProgressView().padding()
                    } else if vm.isEnd, !vm.items.isEmpty {
                        Text("已经到底了")
                            .font(.caption)
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 18)
                    }
                }
            }
            .coordinateSpace(name: "home-feed-scroll")
            .modifier(ScrollOffsetCollapseDriver(progress: $collapseProgress))
            .modifier(ProMotionScrollHint())
        }
        .task { await vm.loadInitial() }
        .refreshable { await vm.refresh() }
    }

    private func prefetchCovers(around item: LiveFeedItemDTO, cardWidth: CGFloat) {
        let lookahead = 18
        guard let idx = vm.items.firstIndex(where: { $0.roomID == item.roomID }) else { return }
        let start = min(idx + 1, vm.items.count)
        let end = min(start + lookahead, vm.items.count)
        guard start < end else { return }
        let covers = vm.items[start..<end].map { $0.systemCover.isEmpty ? $0.cover : $0.systemCover }
        let size = CGSize(width: cardWidth, height: (cardWidth / VideoCoverView.aspectRatio).rounded())
        CoverImagePrefetcher.shared.prefetch(covers,
                                             targetPointSize: size,
                                             quality: settings.resolvedImageQuality())
    }
}
