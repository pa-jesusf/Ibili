import SwiftUI

enum PagedCollectionLayout {
    case list(spacing: CGFloat = 0)
    case grid(columns: [GridItem], spacing: CGFloat = 12, footerColumnSpan: Int = 1)
}

/// Shared paged content renderer for list/grid surfaces.
///
/// This intentionally does not own a `ScrollView`: page chrome, safe-area
/// padding, pull-to-refresh, and scroll restoration belong to the surrounding
/// page shell. Keeping this layer scroll-free prevents nested scroll views and
/// mixed scroll identities while still centralising pagination footers and
/// near-end triggers.
struct PagedCollectionSurface<Item: Identifiable, ItemContent: View, EmptyContent: View>: View where Item.ID: Hashable {
    let items: [Item]
    let layout: PagedCollectionLayout
    let isLoading: Bool
    let isEnd: Bool
    let prefetchThreshold: Int
    let endText: String?
    let onReachEnd: () -> Void
    let onItemAppear: ((Int, Item) -> Void)?
    let emptyContent: () -> EmptyContent
    let itemContent: (Int, Item) -> ItemContent

    init(
        items: [Item],
        layout: PagedCollectionLayout,
        isLoading: Bool,
        isEnd: Bool,
        prefetchThreshold: Int = 4,
        endText: String? = "已经到底了",
        onReachEnd: @escaping () -> Void,
        onItemAppear: ((Int, Item) -> Void)? = nil,
        @ViewBuilder emptyContent: @escaping () -> EmptyContent,
        @ViewBuilder itemContent: @escaping (Int, Item) -> ItemContent
    ) {
        self.items = items
        self.layout = layout
        self.isLoading = isLoading
        self.isEnd = isEnd
        self.prefetchThreshold = prefetchThreshold
        self.endText = endText
        self.onReachEnd = onReachEnd
        self.onItemAppear = onItemAppear
        self.emptyContent = emptyContent
        self.itemContent = itemContent
    }

    var body: some View {
        switch layout {
        case .list(let spacing):
            LazyVStack(alignment: .leading, spacing: spacing) {
                contentRows
                footer
            }
        case .grid(let columns, let spacing, let footerColumnSpan):
            LazyVGrid(columns: columns, alignment: .center, spacing: spacing) {
                contentRows
                footer
                    .gridCellColumns(max(1, footerColumnSpan))
            }
        }
    }

    @ViewBuilder
    private var contentRows: some View {
        if items.isEmpty, !isLoading {
            emptyContent()
        } else {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                itemContent(index, item)
                    .onAppear {
                        onItemAppear?(index, item)
                        guard !isLoading, !isEnd else { return }
                        if index >= max(0, items.count - prefetchThreshold) {
                            onReachEnd()
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if isLoading, !items.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 14)
        } else if isEnd, !items.isEmpty, let endText {
            HStack {
                Spacer()
                Text(endText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 14)
        }
    }
}
