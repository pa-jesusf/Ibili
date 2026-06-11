import SwiftUI
import UIKit

private let virtualizedCollectionCellID = "VirtualizedCollectionCell"
private let virtualizedCollectionHeaderID = "VirtualizedCollectionHeader"

struct VirtualizedCollectionLayout: Equatable {
    enum Kind: Equatable {
        case list(rowHeight: CGFloat)
        case grid(columns: Int, itemHeight: CGFloat, interitemSpacing: CGFloat, lineSpacing: CGFloat)
    }

    var kind: Kind
    var contentInsets: NSDirectionalEdgeInsets

    static func list(rowHeight: CGFloat,
                     contentInsets: NSDirectionalEdgeInsets = .zero) -> Self {
        Self(kind: .list(rowHeight: rowHeight), contentInsets: contentInsets)
    }

    static func grid(columns: Int,
                     itemHeight: CGFloat,
                     interitemSpacing: CGFloat,
                     lineSpacing: CGFloat,
                     contentInsets: NSDirectionalEdgeInsets = .zero) -> Self {
        Self(
            kind: .grid(
                columns: max(1, columns),
                itemHeight: itemHeight,
                interitemSpacing: interitemSpacing,
                lineSpacing: lineSpacing
            ),
            contentInsets: contentInsets
        )
    }
}

struct VirtualizedCollectionView<Item, Content>: UIViewRepresentable
where Item: Identifiable & Hashable, Content: View {
    let items: [Item]
    let layout: VirtualizedCollectionLayout
    let headerTitle: String?
    let scrollToTopSignal: Int
    let isRefreshing: Bool
    let onTap: (Item) -> Void
    let onReachEnd: () -> Void
    let onRefresh: (() -> Void)?
    let onPrefetch: ([Item]) -> Void
    let onCancelPrefetch: ([Item]) -> Void
    let onScrollOffsetChange: (CGFloat) -> Void
    @ViewBuilder let content: (Item) -> Content

    init(items: [Item],
         layout: VirtualizedCollectionLayout,
         headerTitle: String? = nil,
         scrollToTopSignal: Int = 0,
         isRefreshing: Bool = false,
         onTap: @escaping (Item) -> Void = { _ in },
         onReachEnd: @escaping () -> Void = {},
         onRefresh: (() -> Void)? = nil,
         onPrefetch: @escaping ([Item]) -> Void = { _ in },
         onCancelPrefetch: @escaping ([Item]) -> Void = { _ in },
         onScrollOffsetChange: @escaping (CGFloat) -> Void = { _ in },
         @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.layout = layout
        self.headerTitle = headerTitle
        self.scrollToTopSignal = scrollToTopSignal
        self.isRefreshing = isRefreshing
        self.onTap = onTap
        self.onReachEnd = onReachEnd
        self.onRefresh = onRefresh
        self.onPrefetch = onPrefetch
        self.onCancelPrefetch = onCancelPrefetch
        self.onScrollOffsetChange = onScrollOffsetChange
        self.content = content
    }

    func makeUIView(context: Context) -> UICollectionView {
        let collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: makeLayout(containerWidth: 1)
        )
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = context.coordinator
        collectionView.prefetchDataSource = context.coordinator
        collectionView.showsVerticalScrollIndicator = true
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: virtualizedCollectionCellID)
        collectionView.register(
            VirtualizedCollectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: virtualizedCollectionHeaderID
        )
        context.coordinator.collectionView = collectionView
        context.coordinator.installRefreshControlIfNeeded(on: collectionView)
        context.coordinator.apply(items: items, animated: false)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyLayoutIfNeeded(on: collectionView)
        context.coordinator.installRefreshControlIfNeeded(on: collectionView)
        context.coordinator.apply(items: items, animated: false)
        if !isRefreshing {
            collectionView.refreshControl?.endRefreshing()
        }
        if context.coordinator.lastScrollToTopSignal != scrollToTopSignal {
            context.coordinator.lastScrollToTopSignal = scrollToTopSignal
            context.coordinator.scrollToTop(collectionView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func makeLayout(containerWidth: CGFloat) -> UICollectionViewLayout {
        let flow = UICollectionViewFlowLayout()
        flow.sectionInset = UIEdgeInsets(
            top: layout.contentInsets.top,
            left: layout.contentInsets.leading,
            bottom: layout.contentInsets.bottom,
            right: layout.contentInsets.trailing
        )
        switch layout.kind {
        case .list(let rowHeight):
            flow.minimumLineSpacing = 0
            flow.minimumInteritemSpacing = 0
            let width = max(1, containerWidth - layout.contentInsets.leading - layout.contentInsets.trailing)
            flow.itemSize = CGSize(width: width, height: rowHeight)
        case .grid(let columns, let itemHeight, let interitemSpacing, let lineSpacing):
            flow.minimumInteritemSpacing = interitemSpacing
            flow.minimumLineSpacing = lineSpacing
            let available = max(
                1,
                containerWidth
                    - layout.contentInsets.leading
                    - layout.contentInsets.trailing
                    - CGFloat(columns - 1) * interitemSpacing
            )
            let width = floor(available / CGFloat(columns))
            flow.itemSize = CGSize(width: width, height: itemHeight)
        }
        flow.headerReferenceSize = headerTitle == nil
            ? .zero
            : CGSize(width: containerWidth, height: FeedSegmentedHeaderMetrics.expandedHeight)
        return flow
    }

    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDataSourcePrefetching {
        var parent: VirtualizedCollectionView
        weak var collectionView: UICollectionView?
        var lastScrollToTopSignal = 0
        private var currentItems: [Item] = []
        private var lastBoundsWidth: CGFloat = 0
        private var lastLayout: VirtualizedCollectionLayout?
        private var lastHeaderTitle: String?
        private var hasRefreshControl = false

        init(parent: VirtualizedCollectionView) {
            self.parent = parent
        }

        func applyLayoutIfNeeded(on collectionView: UICollectionView) {
            let width = collectionView.bounds.width
            guard abs(width - lastBoundsWidth) > 0.5
                    || lastLayout != parent.layout
                    || lastHeaderTitle != parent.headerTitle else { return }
            lastBoundsWidth = width
            lastLayout = parent.layout
            lastHeaderTitle = parent.headerTitle
            collectionView.setCollectionViewLayout(parent.makeLayout(containerWidth: max(width, 1)), animated: false)
        }

        func apply(items: [Item], animated: Bool) {
            guard let collectionView else { return }
            collectionView.dataSource = self
            guard currentItems != items else { return }

            let oldItems = currentItems
            let oldCount = oldItems.count
            currentItems = items

            guard canAppend(oldItems: oldItems, newItems: items), items.count > oldCount else {
                collectionView.reloadData()
                return
            }

            let inserted = (oldCount..<items.count).map { IndexPath(item: $0, section: 0) }
            guard !inserted.isEmpty else { return }
            collectionView.performBatchUpdates {
                collectionView.insertItems(at: inserted)
            }
        }

        private func canAppend(oldItems: [Item], newItems: [Item]) -> Bool {
            guard !oldItems.isEmpty, newItems.count >= oldItems.count else { return false }
            for index in oldItems.indices {
                let old = oldItems[index]
                let new = newItems[index]
                if old.id != new.id || old != new {
                    return false
                }
            }
            return true
        }

        func installRefreshControlIfNeeded(on collectionView: UICollectionView) {
            if parent.onRefresh == nil {
                collectionView.refreshControl = nil
                hasRefreshControl = false
                return
            }
            guard !hasRefreshControl else { return }
            let refresh = UIRefreshControl()
            refresh.tintColor = UIColor(IbiliTheme.accent)
            refresh.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
            collectionView.refreshControl = refresh
            hasRefreshControl = true
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            currentItems.count
        }

        func collectionView(_ collectionView: UICollectionView,
                            cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: virtualizedCollectionCellID, for: indexPath)
            guard currentItems.indices.contains(indexPath.item) else { return cell }
            let item = currentItems[indexPath.item]
            cell.backgroundColor = .clear
            cell.contentView.backgroundColor = .clear
            cell.contentConfiguration = UIHostingConfiguration {
                parent.content(item)
            }
            .margins(.all, 0)
            return cell
        }

        func collectionView(_ collectionView: UICollectionView,
                            viewForSupplementaryElementOfKind kind: String,
                            at indexPath: IndexPath) -> UICollectionReusableView {
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: virtualizedCollectionHeaderID,
                for: indexPath
            ) as! VirtualizedCollectionHeaderView
            view.configure(title: parent.headerTitle ?? "")
            return view
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard currentItems.indices.contains(indexPath.item) else { return }
            parent.onTap(currentItems[indexPath.item])
        }

        func collectionView(_ collectionView: UICollectionView,
                            willDisplay cell: UICollectionViewCell,
                            forItemAt indexPath: IndexPath) {
            guard !currentItems.isEmpty else { return }
            if indexPath.item >= max(0, currentItems.count - 4) {
                parent.onReachEnd()
            }
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let prefetched = indexPaths.compactMap { currentItems.indices.contains($0.item) ? currentItems[$0.item] : nil }
            if !prefetched.isEmpty {
                parent.onPrefetch(prefetched)
            }
        }

        func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            let cancelled = indexPaths.compactMap { currentItems.indices.contains($0.item) ? currentItems[$0.item] : nil }
            if !cancelled.isEmpty {
                parent.onCancelPrefetch(cancelled)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.onScrollOffsetChange(scrollView.contentOffset.y)
        }

        func scrollToTop(_ collectionView: UICollectionView) {
            let top = CGPoint(x: 0, y: -collectionView.adjustedContentInset.top)
            collectionView.setContentOffset(top, animated: false)
            parent.onScrollOffsetChange(0)
        }

        @objc private func refreshPulled() {
            parent.onRefresh?()
        }
    }
}

private final class VirtualizedCollectionHeaderView: UICollectionReusableView {
    private let gradientView = FeedCollectionHeaderGradientView()
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        addSubview(gradientView)
        titleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.6
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientView.frame = CGRect(
            x: 0,
            y: -24,
            width: bounds.width,
            height: FeedSegmentedHeaderMetrics.expandedHeight + 44
        )
        titleLabel.frame = CGRect(
            x: 16,
            y: 52,
            width: bounds.width - 32,
            height: 40
        )
    }

    func configure(title: String) {
        titleLabel.text = title
    }
}
