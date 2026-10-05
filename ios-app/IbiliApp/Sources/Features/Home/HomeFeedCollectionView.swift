import SwiftUI
import UIKit

struct HomeFeedGridLayoutMetrics: Equatable {
    let containerWidth: CGFloat
    let columns: Int
    let meta: FeedCardMetaConfig

    var cardWidth: CGFloat {
        let horizontalInset: CGFloat = 12
        let spacing: CGFloat = 12
        let totalSpacing = horizontalInset * 2 + spacing * CGFloat(max(0, columns - 1))
        return max(1, floor((containerWidth - totalSpacing) / CGFloat(max(1, columns))))
    }

    var cardHeight: CGFloat {
        HomeFeedCardCell.preferredHeight(width: cardWidth, meta: meta)
    }
}

struct HomeFeedCollectionView: UIViewControllerRepresentable {
    @Environment(\.splitFeedTransitionCoordinator) private var splitTransitionCoordinator
    @Environment(\.splitFeedTransitionConfiguration) private var splitTransitionConfiguration

    let items: [FeedItemDTO]
    let columns: Int
    let imageQuality: Int?
    let meta: FeedCardMetaConfig
    let isLoading: Bool
    let isEnd: Bool
    let scrollToTopSignal: Int
    let scrollState: FeedChromeScrollState
    let onRefresh: () -> Void
    let onLoadMore: () -> Void
    let onOpen: (FeedItemDTO) -> Void
    let onTouchDown: (FeedItemDTO) -> Void
    let onViewportChanged: ([Int]) -> Void
    let onMenuAction: (FeedItemDTO, VideoCardOverflowAction) -> Void

    func makeUIViewController(context: Context) -> HomeFeedCollectionViewController {
        HomeFeedCollectionViewController()
    }

    func updateUIViewController(_ controller: HomeFeedCollectionViewController, context: Context) {
        controller.update(
            items: items,
            columns: columns,
            imageQuality: imageQuality,
            meta: meta,
            isLoading: isLoading,
            isEnd: isEnd,
            scrollToTopSignal: scrollToTopSignal,
            scrollState: scrollState,
            onRefresh: onRefresh,
            onLoadMore: onLoadMore,
            onOpen: onOpen,
            onTouchDown: onTouchDown,
            onViewportChanged: onViewportChanged,
            onMenuAction: onMenuAction,
            splitTransitionCoordinator: splitTransitionCoordinator,
            splitTransitionConfiguration: splitTransitionConfiguration
        )
    }
}

final class HomeFeedCollectionViewController: UIViewController {
    private enum Section: Hashable {
        case content
        case footer
    }

    private enum ItemID: Hashable {
        case card(FeedStableIdentity)
        case footer(HomeFeedFooterState)
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, ItemID>!
    private let snapshotCoordinator = DiffableSnapshotCoordinator<Section, ItemID>()
    private var itemByID: [FeedStableIdentity: FeedItemDTO] = [:]
    private var modelByID: [FeedStableIdentity: MediaCardRenderModel] = [:]
    private var orderedIDs: [FeedStableIdentity] = []
    private var sourceItems: [FeedItemDTO] = []
    private var hasSourceItems = false
    private var imageQuality: Int?
    private var meta: FeedCardMetaConfig = .standard
    private var footerState: HomeFeedFooterState?
    private var configuredColumns = 1
    private var layoutConfiguration: HomeFeedGridLayoutMetrics?
    private var layoutReconfigurationWork: DispatchWorkItem?
    private var lastScrollToTopSignal = 0
    private var visibleIndices: Set<Int> = []
    private var viewportPublishScheduled = false
    private weak var scrollState: FeedChromeScrollState?
    private weak var splitTransitionCoordinator: SplitFeedTransitionCoordinator?
    private var splitTransitionConfiguration: SplitFeedTransitionConfiguration?
    private var pendingAnchor: (id: FeedStableIdentity, screenY: CGFloat, targetWidth: CGFloat)?
    private let refreshControl = UIRefreshControl()

    private var onRefresh: () -> Void = {}
    private var onLoadMore: () -> Void = {}
    private var onOpen: (FeedItemDTO) -> Void = { _ in }
    private var onTouchDown: (FeedItemDTO) -> Void = { _ in }
    private var onViewportChanged: ([Int]) -> Void = { _ in }
    private var onMenuAction: (FeedItemDTO, VideoCardOverflowAction) -> Void = { _, _ in }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.showsVerticalScrollIndicator = true
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

        refreshControl.tintColor = IbiliTheme.refreshIndicatorUIColor
        refreshControl.tintAdjustmentMode = .normal
        refreshControl.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)

        configureDataSource()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayoutIfNeeded()
        applyPendingAnchorIfPossible()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        guard isViewLoaded, collectionView != nil else { return }
        updateLayoutIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        registerSplitTransitionSource()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        splitTransitionCoordinator?.unregister(source: self)
    }

    func update(
        items: [FeedItemDTO],
        columns: Int,
        imageQuality: Int?,
        meta: FeedCardMetaConfig,
        isLoading: Bool,
        isEnd: Bool,
        scrollToTopSignal: Int,
        scrollState: FeedChromeScrollState,
        onRefresh: @escaping () -> Void,
        onLoadMore: @escaping () -> Void,
        onOpen: @escaping (FeedItemDTO) -> Void,
        onTouchDown: @escaping (FeedItemDTO) -> Void,
        onViewportChanged: @escaping ([Int]) -> Void,
        onMenuAction: @escaping (FeedItemDTO, VideoCardOverflowAction) -> Void,
        splitTransitionCoordinator: SplitFeedTransitionCoordinator? = nil,
        splitTransitionConfiguration: SplitFeedTransitionConfiguration? = nil
    ) {
        loadViewIfNeeded()
        let appearanceChanged = self.imageQuality != imageQuality || self.meta != meta
        let sameItems = sourceItems.withUnsafeBufferPointer { old in
            items.withUnsafeBufferPointer { new in old.count == new.count && old.baseAddress == new.baseAddress }
        }
        self.imageQuality = imageQuality
        self.meta = meta
        configuredColumns = max(1, columns)
        self.scrollState = scrollState
        self.onRefresh = onRefresh
        self.onLoadMore = onLoadMore
        self.onOpen = onOpen
        self.onTouchDown = onTouchDown
        self.onViewportChanged = onViewportChanged
        self.onMenuAction = onMenuAction
        if self.splitTransitionCoordinator !== splitTransitionCoordinator {
            self.splitTransitionCoordinator?.unregister(source: self)
        }
        self.splitTransitionCoordinator = splitTransitionCoordinator
        self.splitTransitionConfiguration = splitTransitionConfiguration

        let newFooterState: HomeFeedFooterState? = {
            if isEnd, !items.isEmpty { return .end }
            return nil
        }()
        let previousFooterState = footerState
        footerState = newFooterState

        var snapshotUpdate: (structure: Bool, changed: [FeedStableIdentity])?
        if !sameItems || appearanceChanged || !hasSourceItems {
            var newItems: [FeedStableIdentity: FeedItemDTO] = [:]
            var newModels: [FeedStableIdentity: MediaCardRenderModel] = [:]
            var newIDs: [FeedStableIdentity] = []
            newIDs.reserveCapacity(items.count)
            for item in items {
                let id = FeedStableIdentity(item)
                guard id.isValid, newItems[id] == nil else { continue }
                newItems[id] = item
                newModels[id] = !appearanceChanged && itemByID[id] == item ? modelByID[id] : MediaCardRenderModel(
                    feed: item,
                    imageQuality: imageQuality,
                    meta: meta
                )
                newIDs.append(id)
            }

            let changedIDs = newIDs.filter { modelByID[$0] != newModels[$0] }
            let structureChanged = orderedIDs != newIDs || previousFooterState != newFooterState
            itemByID = newItems
            modelByID = newModels
            orderedIDs = newIDs
            snapshotUpdate = (structureChanged, changedIDs)
            sourceItems = items
            hasSourceItems = true
        } else if previousFooterState != newFooterState {
            snapshotUpdate = (true, [])
        }
        updateRefreshControlAttachment(hasContent: !orderedIDs.isEmpty)
        updateLayoutIfNeeded()
        if let snapshotUpdate { applySnapshot(structureChanged: snapshotUpdate.structure, changedIDs: snapshotUpdate.changed) }
        registerSplitTransitionSource()
        applyPendingAnchorIfPossible()

        if !isLoading, refreshControl.isRefreshing {
            refreshControl.endRefreshing()
        }

        if lastScrollToTopSignal != scrollToTopSignal {
            lastScrollToTopSignal = scrollToTopSignal
            scrollToTop(animated: true)
        }
    }

    private func configureDataSource() {
        let cardRegistration = UICollectionView.CellRegistration<HomeFeedCardCell, FeedStableIdentity> { [weak self] cell, indexPath, id in
            self?.configure(cell, id: id, at: indexPath)
        }
        let footerRegistration = UICollectionView.CellRegistration<HomeFeedFooterCell, HomeFeedFooterState> { cell, _, state in
            cell.configure(state)
        }

        dataSource = UICollectionViewDiffableDataSource<Section, ItemID>(collectionView: collectionView) { collectionView, indexPath, identifier in
            switch identifier {
            case .card(let id):
                return collectionView.dequeueConfiguredReusableCell(using: cardRegistration, for: indexPath, item: id)
            case .footer(let state):
                return collectionView.dequeueConfiguredReusableCell(using: footerRegistration, for: indexPath, item: state)
            }
        }
    }

    private func updateRefreshControlAttachment(hasContent: Bool) {
        if hasContent {
            if collectionView.refreshControl !== refreshControl {
                collectionView.refreshControl = refreshControl
            }
        } else {
            if refreshControl.isRefreshing {
                refreshControl.endRefreshing()
            }
            if collectionView.refreshControl === refreshControl {
                collectionView.refreshControl = nil
            }
        }
    }

    private func applySnapshot(structureChanged: Bool, changedIDs: [FeedStableIdentity]) {
        guard dataSource != nil else { return }
        guard structureChanged || !changedIDs.isEmpty else { return }
        if structureChanged {
            visibleIndices.removeAll(keepingCapacity: true)
            onViewportChanged([])
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, ItemID>()
        snapshot.appendSections([.content])
        snapshot.appendItems(orderedIDs.map(ItemID.card), toSection: .content)
        if let footerState {
            snapshot.appendSections([.footer])
            snapshot.appendItems([.footer(footerState)], toSection: .footer)
        }
        let currentItems = Set(dataSource.snapshot().itemIdentifiers)
        let identifiers = changedIDs
            .map(ItemID.card)
            .filter { currentItems.contains($0) && snapshot.indexOfItem($0) != nil }
        if !identifiers.isEmpty {
            snapshot.reconfigureItems(identifiers)
        }
        snapshotCoordinator.apply(snapshot, to: dataSource)
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let sections = self.dataSource?.snapshot().sectionIdentifiers ?? [.content]
            guard sections.indices.contains(sectionIndex) else { return nil }
            if sections[sectionIndex] == .footer {
                let item = NSCollectionLayoutItem(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1),
                        heightDimension: .absolute(54)
                    )
                )
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: item.layoutSize,
                    subitems: [item]
                )
                return NSCollectionLayoutSection(group: group)
            }

            let columns = max(1, self.configuredColumns)
            let width = max(environment.container.effectiveContentSize.width, 1)
            let config = HomeFeedGridLayoutMetrics(containerWidth: width, columns: columns, meta: self.meta)
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .absolute(config.cardWidth),
                    heightDimension: .absolute(config.cardHeight)
                )
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(config.cardHeight)
                ),
                subitems: Array(repeating: item, count: columns)
            )
            group.interItemSpacing = .fixed(12)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 14
            section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 32, trailing: 12)
            return section
        }
    }

    private func updateLayoutIfNeeded() {
        guard isViewLoaded else { return }
        let width = max(
            collectionView.bounds.width
                - collectionView.adjustedContentInset.left
                - collectionView.adjustedContentInset.right,
            1
        )
        let next = HomeFeedGridLayoutMetrics(containerWidth: width, columns: configuredColumns, meta: meta)
        guard next != layoutConfiguration else { return }
        let layoutDefinitionChanged = layoutConfiguration?.columns != next.columns
            || layoutConfiguration?.meta != next.meta
        layoutConfiguration = next
        if layoutDefinitionChanged {
            collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        } else {
            collectionView.collectionViewLayout.invalidateLayout()
        }
        scheduleVisibleCardReconfiguration(expectedBoundsWidth: collectionView.bounds.width)
    }

    private func scheduleVisibleCardReconfiguration(expectedBoundsWidth: CGFloat) {
        guard expectedBoundsWidth.isFinite, expectedBoundsWidth > 0 else { return }
        layoutReconfigurationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  abs(self.collectionView.bounds.width - expectedBoundsWidth) <= 0.5 else { return }
            self.collectionView.collectionViewLayout.invalidateLayout()
            self.collectionView.layoutIfNeeded()
            for indexPath in self.collectionView.indexPathsForVisibleItems where indexPath.section == 0 {
                guard self.orderedIDs.indices.contains(indexPath.item),
                      let cell = self.collectionView.cellForItem(at: indexPath) as? HomeFeedCardCell else { continue }
                self.configure(cell, id: self.orderedIDs[indexPath.item], at: indexPath)
            }
        }
        layoutReconfigurationWork = work
        DispatchQueue.main.async(execute: work)
    }

    private func configure(
        _ cell: HomeFeedCardCell,
        id: FeedStableIdentity,
        at indexPath: IndexPath
    ) {
        guard let item = itemByID[id], let model = modelByID[id] else { return }
        cell.configure(
            item: item,
            model: model,
            targetWidth: cardWidth(at: indexPath),
            menuAction: { [weak self] action in
                self?.onMenuAction(item, action)
            }
        )
    }

    func cardWidth(at indexPath: IndexPath?) -> CGFloat {
        if let indexPath,
           let width = collectionView.collectionViewLayout
            .layoutAttributesForItem(at: indexPath)?.bounds.width,
           width.isFinite,
           width > 0 {
            return width
        }
        return layoutConfiguration?.cardWidth ?? 180
    }

    private func scrollToTop(animated: Bool) {
        guard isViewLoaded else { return }
        let y = -collectionView.adjustedContentInset.top
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
        scrollState?.reset()
    }

    @objc private func refreshRequested() {
        onRefresh()
    }

    private func scheduleVisibleIndicesPublish(force: Bool = false) {
        guard force || (!collectionView.isDragging && !collectionView.isDecelerating) else { return }
        guard !viewportPublishScheduled else { return }
        viewportPublishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewportPublishScheduled = false
            guard force || (!self.collectionView.isDragging && !self.collectionView.isDecelerating) else { return }
            self.onViewportChanged(self.visibleIndices.sorted())
        }
    }
}

extension HomeFeedCollectionViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let rawOffset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        scrollState?.update(rawOffset: rawOffset)
    }

    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        guard indexPath.section == 0,
              orderedIDs.indices.contains(indexPath.item),
              let item = itemByID[orderedIDs[indexPath.item]] else { return }
        onTouchDown(item)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard indexPath.section == 0,
              orderedIDs.indices.contains(indexPath.item),
              let item = itemByID[orderedIDs[indexPath.item]] else { return }
        onOpen(item)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard indexPath.section == 0, !orderedIDs.isEmpty else { return }
        if visibleIndices.insert(indexPath.item).inserted {
            scheduleVisibleIndicesPublish()
        }
        if indexPath.item >= max(0, orderedIDs.count - 5) {
            onLoadMore()
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard indexPath.section == 0 else { return }
        if visibleIndices.remove(indexPath.item) != nil {
            scheduleVisibleIndicesPublish()
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scheduleVisibleIndicesPublish(force: true)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleVisibleIndicesPublish(force: true)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scheduleVisibleIndicesPublish(force: true)
    }
}

extension HomeFeedCollectionViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let validIndexPaths = indexPaths
            .filter { $0.section == 0 && orderedIDs.indices.contains($0.item) }
        let indices = validIndexPaths
            .map(\.item)
        guard !indices.isEmpty else { return }
        let covers = indices.compactMap { itemByID[orderedIDs[$0]]?.cover }
        let width = validIndexPaths.compactMap { cardWidth(at: $0) }.max()
            ?? layoutConfiguration?.cardWidth
            ?? 180
        CoverImagePrefetcher.shared.prefetch(
            covers,
            targetPointSize: CGSize(width: width, height: width / MediaCardLayout.coverAspectRatio),
            quality: imageQuality
        )
    }
}

extension HomeFeedCollectionViewController: SplitFeedTransitionSource {
    func makeSnapshots(
        direction: SplitFeedTransitionDirection,
        selectedTarget: SplitFeedTransitionTarget?,
        configuration: SplitFeedTransitionConfiguration
    ) -> [SplitFeedCardSnapshot] {
        guard isEligibleSplitTransitionSource, let window = view.window else { return [] }
        let visible = collectionView.indexPathsForVisibleItems
            .filter { $0.section == 0 && orderedIDs.indices.contains($0.item) }
            .compactMap { indexPath -> (IndexPath, UICollectionViewCell, CGRect)? in
                guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
                return (indexPath, cell, cell.convert(cell.bounds, to: window))
            }
        guard !visible.isEmpty else { return [] }

        let anchor: (IndexPath, UICollectionViewCell, CGRect)
        switch direction {
        case .entering:
            guard case .media(let selectedID) = selectedTarget,
                  let selected = visible.first(where: { orderedIDs[$0.0.item] == selectedID }) else {
                return []
            }
            anchor = selected
        case .exiting:
            anchor = topRightVisibleEntry(visible)
        }

        let targetWidth: CGFloat
        let targetColumns: Int
        switch direction {
        case .entering:
            targetWidth = configuration.targetLeftWidth
            targetColumns = max(1, configuration.splitColumns)
        case .exiting:
            targetWidth = configuration.containerSize.width
            targetColumns = max(1, configuration.fullColumns)
        }
        let metrics = HomeFeedGridLayoutMetrics(
            containerWidth: max(1, targetWidth),
            columns: targetColumns,
            meta: meta
        )
        let anchorIndex = anchor.0.item
        let targetGeometry = SplitFeedGridGeometry(
            columns: targetColumns,
            itemWidth: metrics.cardWidth,
            itemHeight: metrics.cardHeight,
            horizontalInset: 12,
            interitemSpacing: 12,
            rowSpacing: 14
        )
        pendingAnchor = (
            id: orderedIDs[anchorIndex],
            screenY: anchor.2.minY,
            targetWidth: targetWidth
        )

        return visible.compactMap { indexPath, cell, startFrame in
            guard let snapshot = cell.snapshotView(afterScreenUpdates: false) else { return nil }
            let index = indexPath.item
            let endFrame = targetGeometry.frame(
                for: index,
                anchorIndex: anchorIndex,
                anchorScreenY: anchor.2.minY
            )
            snapshot.clipsToBounds = true
            return SplitFeedCardSnapshot(view: snapshot, startFrame: startFrame, endFrame: endFrame)
        }
    }

    func setTransitionCardsHidden(_ hidden: Bool) {
        collectionView.alpha = hidden ? 0 : 1
    }

    private func registerSplitTransitionSource() {
        splitTransitionCoordinator?.register(
            source: self,
            configuration: splitTransitionConfiguration
        )
    }

    private var isEligibleSplitTransitionSource: Bool {
        guard isViewLoaded, let window = collectionView.window else { return false }
        return SplitFeedTransitionVisibility.isVisible(collectionView, in: window)
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

    private func applyPendingAnchorIfPossible() {
        guard let pendingAnchor,
              abs(collectionView.bounds.width - pendingAnchor.targetWidth) <= 2,
              let index = orderedIDs.firstIndex(of: pendingAnchor.id) else { return }
        collectionView.layoutIfNeeded()
        let indexPath = IndexPath(item: index, section: 0)
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

private enum HomeFeedFooterState: Hashable {
    case end
}

private final class HomeFeedFooterCell: UICollectionViewCell {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds.insetBy(dx: 12, dy: 8)
    }

    func configure(_ state: HomeFeedFooterState) {
        label.text = state == .end ? "已经到底了" : nil
    }
}

final class HomeFeedCardCell: UICollectionViewCell {
    let card = MediaCardContentView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(card)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        card.reset()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = contentView.bounds
    }

    func configure(
        item: FeedItemDTO,
        model: MediaCardRenderModel,
        targetWidth: CGFloat,
        menuAction: @escaping (VideoCardOverflowAction) -> Void
    ) {
        card.configure(model: model, targetWidth: targetWidth, menu: VideoCardOverflowMenuBuilder.makeMenu(
            bvid: item.bvid,
            author: item.author,
            ownerMID: item.ownerMID,
            dislikeReasons: item.dislikeReasons,
            feedbackReasons: item.feedbackReasons,
            actionHandler: menuAction
        ))
        accessibilityLabel = card.accessibilityLabel
        accessibilityTraits = .button
    }

    static func preferredHeight(width: CGFloat, meta: FeedCardMetaConfig) -> CGFloat {
        MediaCardContentView.preferredHeight(width: width, meta: meta)
    }
}
