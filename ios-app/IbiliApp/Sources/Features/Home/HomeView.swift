import SwiftUI
import UIKit

struct HomeView: View {
    @State private var section: HomeFeedSection = .recommend
    @StateObject private var recommendVM: HomeViewModel
    @StateObject private var hotVM: HomeViewModel
    @StateObject private var prefetch = FeedPrefetchCoordinator()

    init() {
        _recommendVM = StateObject(wrappedValue: HomeViewModel(section: .recommend))
        _hotVM = StateObject(wrappedValue: HomeViewModel(section: .hot))
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionPicker
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            HomeFeedPage(vm: activeViewModel, prefetch: prefetch)
        }
        .background(IbiliTheme.background.ignoresSafeArea())
    }

    private var activeViewModel: HomeViewModel {
        switch section {
        case .recommend:
            return recommendVM
        case .hot:
            return hotVM
        }
    }

    @ViewBuilder
    private var sectionPicker: some View {
        if #available(iOS 26.0, *) {
            NativeIsolatedPicker(
                items: Array(HomeFeedSection.allCases),
                title: { $0.title },
                selection: $section
            )
            .frame(height: 50)
        } else {
            IbiliSegmentedTabs(
                tabs: Array(HomeFeedSection.allCases),
                title: { $0.title },
                selection: $section
            )
        }
    }
}

private struct HomeFeedPage: View {
    @ObservedObject var vm: HomeViewModel
    let prefetch: FeedPrefetchCoordinator

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DeepLinkRouter
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        Group {
            if vm.items.isEmpty && vm.isLoading {
                ProgressView().tint(IbiliTheme.accent)
            } else if let err = vm.errorText, vm.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                    Text(err).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("重试") { Task { await vm.refresh() } }
                        .buttonStyle(.borderedProminent).tint(IbiliTheme.accent)
                }
                .padding()
            } else {
                feedGrid
            }
        }
        .task { await vm.loadInitial() }
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
                .padding(.vertical, 8)

                if vm.isLoading && !vm.items.isEmpty {
                    ProgressView().padding()
                } else if vm.isEnd, !vm.items.isEmpty {
                    Text("已经到底了")
                        .font(.caption)
                        .foregroundStyle(IbiliTheme.textSecondary)
                        .padding(.bottom, 18)
                }
            }
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
