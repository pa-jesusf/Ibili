import SwiftUI
import UIKit

struct VirtualizedCollectionLayout: Equatable {
    enum Height: Equatable {
        case absolute(CGFloat)
        case estimated(CGFloat)
    }

    var columns: Int = 1
    var horizontalInset: CGFloat = 0
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var interitemSpacing: CGFloat = 0
    var rowSpacing: CGFloat = 0
    var height: Height = .estimated(180)

    static func list(
        horizontalInset: CGFloat = 0,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        spacing: CGFloat = 0,
        estimatedHeight: CGFloat = 180
    ) -> Self {
        Self(
            columns: 1,
            horizontalInset: horizontalInset,
            topInset: topInset,
            bottomInset: bottomInset,
            interitemSpacing: 0,
            rowSpacing: spacing,
            height: .estimated(estimatedHeight)
        )
    }

    static func grid(
        columns: Int,
        horizontalInset: CGFloat = 12,
        topInset: CGFloat = 8,
        bottomInset: CGFloat = 32,
        interitemSpacing: CGFloat = 12,
        rowSpacing: CGFloat = 14,
        height: Height
    ) -> Self {
        Self(
            columns: max(1, columns),
            horizontalInset: horizontalInset,
            topInset: topInset,
            bottomInset: bottomInset,
            interitemSpacing: interitemSpacing,
            rowSpacing: rowSpacing,
            height: height
        )
    }

    func itemWidth(containerWidth: CGFloat) -> CGFloat {
        let count = max(1, columns)
        let occupied = horizontalInset * 2 + interitemSpacing * CGFloat(count - 1)
        return max(1, floor((containerWidth - occupied) / CGFloat(count)))
    }
}

/// Shared virtualized surface for pages that need UIKit reuse and diffing but
/// should keep their existing SwiftUI card implementations. The scroll owner,
/// snapshot, viewport and pagination behavior live here; feature modules only
/// provide stable data and cell/header/footer views.
struct VirtualizedCollectionSurface<Item: Identifiable & Hashable>: UIViewControllerRepresentable where Item.ID: Hashable {
    @Environment(\.splitFeedTransitionCoordinator) private var splitTransitionCoordinator
    @Environment(\.splitFeedTransitionConfiguration) private var splitTransitionConfiguration

    let items: [Item]
    let layout: VirtualizedCollectionLayout
    var header: (() -> AnyView)? = nil
    var footer: (() -> AnyView)? = nil
    var showsRefresh = false
    var scrollToTopSignal = 0
    var prefetchThreshold = 4
    var scrollState: FeedChromeScrollState? = nil
    var onRefresh: () -> Void = {}
    var onLoadMore: () -> Void = {}
    var onOpen: ((Item) -> Void)? = nil
    var onPrefetch: ([Item], CGFloat) -> Void = { _, _ in }
    var onViewportChanged: ([Item]) -> Void = { _ in }
    var onScrollOffsetChanged: (CGFloat) -> Void = { _ in }
    var splitTransitionIdentity: ((Item) -> FeedStableIdentity?)? = nil
    var splitTransitionHeight: ((Item, CGFloat) -> CGFloat?)? = nil
    var contentVersion: AnyHashable = 0
    let content: (Item, CGFloat) -> AnyView

    func makeUIViewController(context: Context) -> VirtualizedCollectionViewController<Item> {
        VirtualizedCollectionViewController()
    }

    func updateUIViewController(_ controller: VirtualizedCollectionViewController<Item>, context: Context) {
        controller.update(
            items: items,
            layout: layout,
            header: header,
            footer: footer,
            showsRefresh: showsRefresh,
            scrollToTopSignal: scrollToTopSignal,
            prefetchThreshold: prefetchThreshold,
            scrollState: scrollState,
            onRefresh: onRefresh,
            onLoadMore: onLoadMore,
            onOpen: onOpen,
            onPrefetch: onPrefetch,
            onViewportChanged: onViewportChanged,
            onScrollOffsetChanged: onScrollOffsetChanged,
            splitTransitionCoordinator: splitTransitionCoordinator,
            splitTransitionConfiguration: splitTransitionConfiguration,
            splitTransitionIdentity: splitTransitionIdentity,
            splitTransitionHeight: splitTransitionHeight,
            contentVersion: contentVersion,
            content: content
        )
    }
}

@MainActor
final class VirtualizedCollectionViewController<Item: Identifiable & Hashable>: UIViewController,
    UICollectionViewDelegate,
    UICollectionViewDataSourcePrefetching where Item.ID: Hashable {

    private enum Section: Hashable {
        case header
        case content
        case footer
    }

    private enum ElementID: Hashable {
        case header
        case item(Item.ID)
        case footer
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, ElementID>!
    private let snapshotCoordinator = DiffableSnapshotCoordinator<Section, ElementID>()
    private var orderedIDs: [Item.ID] = []
    private var itemByID: [Item.ID: Item] = [:]
    private var layoutConfiguration = VirtualizedCollectionLayout.list()
    private var hasHeader = false
    private var hasFooter = false
    private var headerProvider: (() -> AnyView)?
    private var footerProvider: (() -> AnyView)?
    private var contentProvider: (Item, CGFloat) -> AnyView = { _, _ in AnyView(EmptyView()) }
    private var prefetchThreshold = 4
    private var lastScrollToTopSignal = 0
    private var visibleIDs: Set<Item.ID> = []
    private var viewportPublishScheduled = false
    private weak var scrollState: FeedChromeScrollState?
    private weak var splitTransitionCoordinator: SplitFeedTransitionCoordinator?
    private var splitTransitionConfiguration: SplitFeedTransitionConfiguration?
    private var splitTransitionIdentity: ((Item) -> FeedStableIdentity?)?
    private var splitTransitionHeight: ((Item, CGFloat) -> CGFloat?)?
    private var pendingAnchor: (id: Item.ID, screenY: CGFloat, targetWidth: CGFloat)?
    private var reflowsAcrossSplit = false
    private var contentVersion: AnyHashable = 0
    private var lastLaidOutWidth: CGFloat = 0

    private var onRefresh: () -> Void = {}
    private var onLoadMore: () -> Void = {}
    private var onOpen: ((Item) -> Void)?
    private var onPrefetch: ([Item], CGFloat) -> Void = { _, _ in }
    private var onViewportChanged: ([Item]) -> Void = { _ in }
    private var onScrollOffsetChanged: (CGFloat) -> Void = { _ in }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        if #available(iOS 16.0, *) {
            collectionView.isPrefetchingEnabled = true
        }
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let refreshControl = UIRefreshControl()
        refreshControl.tintColor = IbiliTheme.accentUIColor
        refreshControl.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)
        collectionView.refreshControl = refreshControl
        configureDataSource()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        registerSplitTransitionSource()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        splitTransitionCoordinator?.unregister(source: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = collectionView.bounds.width
        if abs(width - lastLaidOutWidth) > 0.5 {
            lastLaidOutWidth = width
            collectionView.collectionViewLayout.invalidateLayout()
            reconfigureContentItems()
        }
        applyPendingAnchorIfPossible()
    }

    func update(
        items: [Item],
        layout: VirtualizedCollectionLayout,
        header: (() -> AnyView)?,
        footer: (() -> AnyView)?,
        showsRefresh: Bool,
        scrollToTopSignal: Int,
        prefetchThreshold: Int,
        scrollState: FeedChromeScrollState?,
        onRefresh: @escaping () -> Void,
        onLoadMore: @escaping () -> Void,
        onOpen: ((Item) -> Void)?,
        onPrefetch: @escaping ([Item], CGFloat) -> Void,
        onViewportChanged: @escaping ([Item]) -> Void,
        onScrollOffsetChanged: @escaping (CGFloat) -> Void,
        splitTransitionCoordinator: SplitFeedTransitionCoordinator?,
        splitTransitionConfiguration: SplitFeedTransitionConfiguration?,
        splitTransitionIdentity: ((Item) -> FeedStableIdentity?)?,
        splitTransitionHeight: ((Item, CGFloat) -> CGFloat?)?,
        contentVersion: AnyHashable,
        content: @escaping (Item, CGFloat) -> AnyView
    ) {
        loadViewIfNeeded()
        let oldItems = itemByID
        let nextHeader = header != nil
        let nextFooter = footer != nil
        let structureChanged = orderedIDs != items.map(\.id)
            || hasHeader != nextHeader
            || hasFooter != nextFooter

        let layoutChanged = layoutConfiguration != layout
            || hasHeader != nextHeader
            || hasFooter != nextFooter
        layoutConfiguration = layout
        hasHeader = nextHeader
        hasFooter = nextFooter
        headerProvider = header
        footerProvider = footer
        contentProvider = content
        self.prefetchThreshold = max(1, prefetchThreshold)
        self.scrollState = scrollState
        self.onRefresh = onRefresh
        self.onLoadMore = onLoadMore
        self.onOpen = onOpen
        self.onPrefetch = onPrefetch
        self.onViewportChanged = onViewportChanged
        self.onScrollOffsetChanged = onScrollOffsetChanged
        if self.splitTransitionCoordinator !== splitTransitionCoordinator {
            self.splitTransitionCoordinator?.unregister(source: self)
        }
        self.splitTransitionCoordinator = splitTransitionCoordinator
        self.splitTransitionConfiguration = splitTransitionConfiguration
        self.splitTransitionIdentity = splitTransitionIdentity
        self.splitTransitionHeight = splitTransitionHeight
        collectionView.refreshControl?.isHidden = !showsRefresh

        var nextItems: [Item.ID: Item] = [:]
        var nextIDs: [Item.ID] = []
        nextIDs.reserveCapacity(items.count)
        for item in items where nextItems[item.id] == nil {
            nextItems[item.id] = item
            nextIDs.append(item.id)
        }
        let contentChanged = self.contentVersion != contentVersion
        self.contentVersion = contentVersion
        let changedIDs = layoutChanged || contentChanged
            ? nextIDs
            : nextIDs.filter { oldItems[$0] != nextItems[$0] }
        itemByID = nextItems
        orderedIDs = nextIDs

        if layoutChanged {
            collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        }
        applySnapshot(structureChanged: structureChanged, changedIDs: changedIDs)
        registerSplitTransitionSource()
        applyPendingAnchorIfPossible()

        if collectionView.refreshControl?.isRefreshing == true {
            collectionView.refreshControl?.endRefreshing()
        }
        if lastScrollToTopSignal != scrollToTopSignal {
            lastScrollToTopSignal = scrollToTopSignal
            scrollToTop(animated: true)
        }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewCell, ElementID> { [weak self] cell, _, element in
            guard let self else { return }
            cell.backgroundColor = .clear
            let hosted: AnyView
            switch element {
            case .header:
                hosted = self.headerProvider?() ?? AnyView(EmptyView())
            case .footer:
                hosted = self.footerProvider?() ?? AnyView(EmptyView())
            case .item(let id):
                guard let item = self.itemByID[id] else { return }
                hosted = self.contentProvider(item, self.currentItemWidth)
            }
            cell.contentConfiguration = UIHostingConfiguration {
                hosted
            }
            .margins(.all, 0)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, ElementID>(collectionView: collectionView) {
            collectionView, indexPath, element in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: element)
        }
    }

    private func applySnapshot(structureChanged: Bool, changedIDs: [Item.ID]) {
        if structureChanged {
            visibleIDs.removeAll(keepingCapacity: true)
            onViewportChanged([])
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, ElementID>()
        if hasHeader {
            snapshot.appendSections([.header])
            snapshot.appendItems([.header], toSection: .header)
        }
        snapshot.appendSections([.content])
        snapshot.appendItems(orderedIDs.map(ElementID.item), toSection: .content)
        if hasFooter {
            snapshot.appendSections([.footer])
            snapshot.appendItems([.footer], toSection: .footer)
        }

        let currentItems = Set(dataSource.snapshot().itemIdentifiers)
        var reconfigured = changedIDs.map(ElementID.item)
        if hasHeader { reconfigured.append(.header) }
        if hasFooter { reconfigured.append(.footer) }
        let existing = reconfigured.filter {
            currentItems.contains($0) && snapshot.indexOfItem($0) != nil
        }
        if !existing.isEmpty {
            snapshot.reconfigureItems(existing)
        }
        snapshotCoordinator.apply(snapshot, to: dataSource)
    }

    private func reconfigureContentItems() {
        guard dataSource != nil, !orderedIDs.isEmpty else { return }
        applySnapshot(structureChanged: false, changedIDs: orderedIDs)
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let sections = self.dataSource?.snapshot().sectionIdentifiers ?? self.currentSections
            guard sections.indices.contains(sectionIndex) else { return nil }
            switch sections[sectionIndex] {
            case .header, .footer:
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(56)
                ))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: item.layoutSize, subitems: [item])
                return NSCollectionLayoutSection(group: group)
            case .content:
                let config = self.layoutConfiguration
                let width = max(1, environment.container.effectiveContentSize.width)
                let itemWidth = config.itemWidth(containerWidth: width)
                let height: NSCollectionLayoutDimension
                switch config.height {
                case .absolute(let value): height = .absolute(max(1, value))
                case .estimated(let value): height = .estimated(max(1, value))
                }
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                    widthDimension: .absolute(itemWidth),
                    heightDimension: height
                ))
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1),
                        heightDimension: height
                    ),
                    subitems: Array(repeating: item, count: max(1, config.columns))
                )
                group.interItemSpacing = .fixed(config.interitemSpacing)
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = config.rowSpacing
                section.contentInsets = NSDirectionalEdgeInsets(
                    top: config.topInset,
                    leading: config.horizontalInset,
                    bottom: config.bottomInset,
                    trailing: config.horizontalInset
                )
                return section
            }
        }
    }

    private var currentSections: [Section] {
        var result: [Section] = []
        if hasHeader { result.append(.header) }
        result.append(.content)
        if hasFooter { result.append(.footer) }
        return result
    }

    private var contentSectionIndex: Int {
        hasHeader ? 1 : 0
    }

    private var currentItemWidth: CGFloat {
        layoutConfiguration.itemWidth(containerWidth: max(1, collectionView.bounds.width))
    }

    @objc private func refreshRequested() {
        onRefresh()
    }

    private func scrollToTop(animated: Bool) {
        let y = -collectionView.adjustedContentInset.top
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
        scrollState?.reset()
    }

    private func scheduleViewportPublish(force: Bool = false) {
        guard force || (!collectionView.isDragging && !collectionView.isDecelerating) else { return }
        guard !viewportPublishScheduled else { return }
        viewportPublishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewportPublishScheduled = false
            guard force || (!self.collectionView.isDragging && !self.collectionView.isDecelerating) else { return }
            let items = self.orderedIDs.compactMap { id in
                self.visibleIDs.contains(id) ? self.itemByID[id] : nil
            }
            self.onViewportChanged(items)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let rawOffset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        scrollState?.update(rawOffset: rawOffset)
        onScrollOffsetChanged(rawOffset)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scheduleViewportPublish(force: true) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleViewportPublish(force: true)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scheduleViewportPublish(force: true)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.section == contentSectionIndex,
              orderedIDs.indices.contains(indexPath.item),
              let item = itemByID[orderedIDs[indexPath.item]] else { return }
        onOpen?(item)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard indexPath.section == contentSectionIndex,
              orderedIDs.indices.contains(indexPath.item) else { return }
        let id = orderedIDs[indexPath.item]
        if visibleIDs.insert(id).inserted { scheduleViewportPublish() }
        if indexPath.item >= max(0, orderedIDs.count - prefetchThreshold) {
            onLoadMore()
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard indexPath.section == contentSectionIndex,
              orderedIDs.indices.contains(indexPath.item) else { return }
        if visibleIDs.remove(orderedIDs[indexPath.item]) != nil {
            scheduleViewportPublish()
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let items = indexPaths.compactMap { indexPath -> Item? in
            guard indexPath.section == contentSectionIndex,
                  orderedIDs.indices.contains(indexPath.item) else { return nil }
            return itemByID[orderedIDs[indexPath.item]]
        }
        guard !items.isEmpty else { return }
        onPrefetch(items, currentItemWidth)
    }
}

extension VirtualizedCollectionViewController: SplitFeedTransitionSource {
    func makeSnapshots(
        direction: SplitFeedTransitionDirection,
        selectedID: FeedStableIdentity?,
        configuration: SplitFeedTransitionConfiguration
    ) -> [SplitFeedCardSnapshot] {
        guard isEligibleSplitTransitionSource,
              let identity = splitTransitionIdentity,
              let window = view.window else { return [] }

        let visible = collectionView.indexPathsForVisibleItems
            .filter { $0.section == contentSectionIndex && orderedIDs.indices.contains($0.item) }
            .compactMap { indexPath -> (IndexPath, UICollectionViewCell, CGRect)? in
                guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
                return (indexPath, cell, cell.convert(cell.bounds, to: window))
            }
        guard !visible.isEmpty else { return [] }

        let anchor: (IndexPath, UICollectionViewCell, CGRect)
        switch direction {
        case .entering:
            guard let selectedID,
                  let selected = visible.first(where: { entry in
                      guard let item = itemByID[orderedIDs[entry.0.item]] else { return false }
                      return identity(item) == selectedID
                  }) else { return [] }
            anchor = selected
            reflowsAcrossSplit = collectionView.bounds.width > configuration.targetLeftWidth + 2
        case .exiting:
            anchor = topRightVisibleEntry(visible)
        }

        let currentWidth = max(collectionView.bounds.width, 1)
        let targetCollectionWidth: CGFloat
        let targetCollectionX: CGFloat
        let targetColumns: Int
        switch direction {
        case .entering:
            targetCollectionWidth = reflowsAcrossSplit ? configuration.targetLeftWidth : currentWidth
            targetCollectionX = 0
            targetColumns = reflowsAcrossSplit
                ? min(max(1, layoutConfiguration.columns), max(1, configuration.splitColumns))
                : max(1, layoutConfiguration.columns)
        case .exiting:
            targetCollectionWidth = reflowsAcrossSplit ? configuration.containerSize.width : currentWidth
            targetCollectionX = reflowsAcrossSplit
                ? 0
                : max(0, (configuration.containerSize.width - currentWidth) / 2)
            targetColumns = reflowsAcrossSplit
                ? max(1, configuration.fullColumns)
                : max(1, layoutConfiguration.columns)
        }

        let targetItemWidth = layoutConfiguration.itemWidth(
            containerWidth: max(1, targetCollectionWidth)
        )
        let currentItemWidth = max(1, layoutConfiguration.itemWidth(containerWidth: currentWidth))
        let anchorIndex = anchor.0.item
        let targetAnchorHeight = targetHeight(
            at: anchorIndex,
            currentHeight: anchor.2.height,
            currentItemWidth: currentItemWidth,
            targetItemWidth: targetItemWidth
        )
        let targetGeometry = SplitFeedGridGeometry(
            columns: targetColumns,
            itemWidth: targetItemWidth,
            itemHeight: targetAnchorHeight,
            horizontalInset: layoutConfiguration.horizontalInset,
            interitemSpacing: layoutConfiguration.interitemSpacing,
            rowSpacing: layoutConfiguration.rowSpacing
        )
        pendingAnchor = (
            id: orderedIDs[anchorIndex],
            screenY: anchor.2.minY,
            targetWidth: targetCollectionWidth
        )

        return visible.compactMap { indexPath, cell, startFrame in
            guard let snapshot = cell.snapshotView(afterScreenUpdates: false) else { return nil }
            let index = indexPath.item
            let height = targetHeight(
                at: index,
                currentHeight: startFrame.height,
                currentItemWidth: currentItemWidth,
                targetItemWidth: targetItemWidth
            )
            let endFrame = targetGeometry.frame(
                for: index,
                anchorIndex: anchorIndex,
                anchorScreenY: anchor.2.minY,
                originX: targetCollectionX,
                height: height
            )
            snapshot.clipsToBounds = true
            return SplitFeedCardSnapshot(view: snapshot, startFrame: startFrame, endFrame: endFrame)
        }
    }

    func setTransitionCardsHidden(_ hidden: Bool) {
        collectionView.alpha = hidden ? 0 : 1
    }

    private func registerSplitTransitionSource() {
        guard splitTransitionIdentity != nil else {
            splitTransitionCoordinator?.unregister(source: self)
            return
        }
        splitTransitionCoordinator?.register(
            source: self,
            configuration: splitTransitionConfiguration
        )
    }

    private var isEligibleSplitTransitionSource: Bool {
        guard isViewLoaded, view.window != nil, view.bounds.width > 1, view.bounds.height > 1 else {
            return false
        }
        var candidate: UIView? = view
        while let current = candidate {
            if current.isHidden || current.alpha < 0.01 { return false }
            candidate = current.superview
        }
        guard let window = view.window else { return false }
        let frame = view.convert(view.bounds, to: window)
        return !frame.intersection(window.bounds).isNull
            && frame.intersection(window.bounds).width > 1
            && frame.intersection(window.bounds).height > 1
    }

    private func topRightVisibleEntry(
        _ entries: [(IndexPath, UICollectionViewCell, CGRect)]
    ) -> (IndexPath, UICollectionViewCell, CGRect) {
        let frames = entries.map { (index: $0.0.item, frame: $0.2) }
        guard let index = SplitFeedGridGeometry.topRightIndex(in: frames),
              let match = entries.first(where: { $0.0.item == index }) else {
            return entries.min(by: { $0.2.minY < $1.2.minY })!
        }
        return match
    }

    private func targetHeight(
        at index: Int,
        currentHeight: CGFloat,
        currentItemWidth: CGFloat,
        targetItemWidth: CGFloat
    ) -> CGFloat {
        guard orderedIDs.indices.contains(index), let item = itemByID[orderedIDs[index]] else {
            return max(1, currentHeight)
        }
        if let resolved = splitTransitionHeight?(item, targetItemWidth), resolved > 0 {
            return resolved
        }
        guard reflowsAcrossSplit else { return max(1, currentHeight) }
        return max(1, currentHeight * targetItemWidth / max(1, currentItemWidth))
    }

    private func applyPendingAnchorIfPossible() {
        guard let pendingAnchor,
              abs(collectionView.bounds.width - pendingAnchor.targetWidth) <= 2,
              let index = orderedIDs.firstIndex(of: pendingAnchor.id) else { return }
        collectionView.layoutIfNeeded()
        let indexPath = IndexPath(item: index, section: contentSectionIndex)
        guard let attributes = collectionView.collectionViewLayout.layoutAttributesForItem(at: indexPath),
              let window = collectionView.window else { return }
        let collectionFrame = collectionView.convert(collectionView.bounds, to: window)
        let minimumY = -collectionView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            collectionView.collectionViewLayout.collectionViewContentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        let targetY = SplitFeedGridGeometry.contentOffsetY(
            anchorContentY: attributes.frame.minY,
            anchorScreenY: pendingAnchor.screenY,
            collectionScreenMinY: collectionFrame.minY,
            minimumY: minimumY,
            maximumY: maximumY
        )
        collectionView.setContentOffset(
            CGPoint(x: 0, y: targetY),
            animated: false
        )
        self.pendingAnchor = nil
    }
}
