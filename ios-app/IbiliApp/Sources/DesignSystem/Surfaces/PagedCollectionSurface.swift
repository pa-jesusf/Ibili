import SwiftUI

struct PagedCollectionSurface<Item: Identifiable & Hashable, Content: View>: View {
    let items: [Item]
    let layout: VirtualizedCollectionLayout
    var headerTitle: String? = nil
    var scrollToTopSignal: Int = 0
    var isInitialLoading: Bool = false
    var isRefreshing: Bool = false
    var isLoadingMore: Bool = false
    var isEnd: Bool = false
    var errorText: String? = nil
    var emptyState: SurfaceState
    var onTap: (Item) -> Void = { _ in }
    var onReachEnd: () -> Void = {}
    var onRefresh: (() -> Void)? = nil
    var onPrefetch: ([Item]) -> Void = { _ in }
    var onCancelPrefetch: ([Item]) -> Void = { _ in }
    var onScrollOffsetChange: (CGFloat) -> Void = { _ in }
    let row: (Item) -> Content

    init(
        items: [Item],
        layout: VirtualizedCollectionLayout,
        headerTitle: String? = nil,
        scrollToTopSignal: Int = 0,
        isInitialLoading: Bool = false,
        isRefreshing: Bool = false,
        isLoadingMore: Bool = false,
        isEnd: Bool = false,
        errorText: String? = nil,
        emptyState: SurfaceState,
        onTap: @escaping (Item) -> Void = { _ in },
        onReachEnd: @escaping () -> Void = {},
        onRefresh: (() -> Void)? = nil,
        onPrefetch: @escaping ([Item]) -> Void = { _ in },
        onCancelPrefetch: @escaping ([Item]) -> Void = { _ in },
        onScrollOffsetChange: @escaping (CGFloat) -> Void = { _ in },
        @ViewBuilder row: @escaping (Item) -> Content
    ) {
        self.items = items
        self.layout = layout
        self.headerTitle = headerTitle
        self.scrollToTopSignal = scrollToTopSignal
        self.isInitialLoading = isInitialLoading
        self.isRefreshing = isRefreshing
        self.isLoadingMore = isLoadingMore
        self.isEnd = isEnd
        self.errorText = errorText
        self.emptyState = emptyState
        self.onTap = onTap
        self.onReachEnd = onReachEnd
        self.onRefresh = onRefresh
        self.onPrefetch = onPrefetch
        self.onCancelPrefetch = onCancelPrefetch
        self.onScrollOffsetChange = onScrollOffsetChange
        self.row = row
    }

    var body: some View {
        ZStack {
            if items.isEmpty {
                emptyBody
            } else {
                listBody
            }
        }
    }

    @ViewBuilder
    private var emptyBody: some View {
        if let errorText, !errorText.isEmpty {
            StateView(
                state: .error(message: errorText),
                onRetry: onRefresh
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isInitialLoading {
            StateView(state: .loading())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            StateView(state: emptyState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var listBody: some View {
        GeometryReader { proxy in
            VirtualizedCollectionView(
                items: items,
                layout: layout,
                headerTitle: headerTitle,
                scrollToTopSignal: scrollToTopSignal,
                isRefreshing: isRefreshing,
                onTap: onTap,
                onReachEnd: onReachEnd,
                onRefresh: onRefresh,
                onPrefetch: onPrefetch,
                onCancelPrefetch: onCancelPrefetch,
                onScrollOffsetChange: onScrollOffsetChange,
                content: row
            )
            .overlay(alignment: .bottom) {
                bottomStatus(bottomSafeArea: proxy.safeAreaInsets.bottom)
            }
        }
    }

    @ViewBuilder
    private func bottomStatus(bottomSafeArea: CGFloat) -> some View {
        if isLoadingMore {
            ProgressView()
                .padding(10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, max(14, bottomSafeArea + 10))
        } else if isEnd {
            Text("已经到底了")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, max(14, bottomSafeArea + 10))
        }
    }
}
