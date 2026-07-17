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
    let items: [FeedItemDTO]
    let columns: Int
    let imageQuality: Int?
    let meta: FeedCardMetaConfig
    let usesTopTrailingDuration: Bool
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
            usesTopTrailingDuration: usesTopTrailingDuration,
            isLoading: isLoading,
            isEnd: isEnd,
            scrollToTopSignal: scrollToTopSignal,
            scrollState: scrollState,
            onRefresh: onRefresh,
            onLoadMore: onLoadMore,
            onOpen: onOpen,
            onTouchDown: onTouchDown,
            onViewportChanged: onViewportChanged,
            onMenuAction: onMenuAction
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
    private var itemByID: [FeedStableIdentity: FeedItemDTO] = [:]
    private var modelByID: [FeedStableIdentity: MediaCardRenderModel] = [:]
    private var orderedIDs: [FeedStableIdentity] = []
    private var imageQuality: Int?
    private var meta: FeedCardMetaConfig = .standard
    private var usesTopTrailingDuration = false
    private var footerState: HomeFeedFooterState?
    private var configuredColumns = 1
    private var layoutConfiguration: HomeFeedGridLayoutMetrics?
    private var lastScrollToTopSignal = 0
    private var visibleIndices: Set<Int> = []
    private var viewportPublishScheduled = false
    private weak var scrollState: FeedChromeScrollState?

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

        let refreshControl = UIRefreshControl()
        refreshControl.tintColor = IbiliTheme.accentUIColor
        refreshControl.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)
        collectionView.refreshControl = refreshControl

        configureDataSource()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayoutIfNeeded()
    }

    func update(
        items: [FeedItemDTO],
        columns: Int,
        imageQuality: Int?,
        meta: FeedCardMetaConfig,
        usesTopTrailingDuration: Bool,
        isLoading: Bool,
        isEnd: Bool,
        scrollToTopSignal: Int,
        scrollState: FeedChromeScrollState,
        onRefresh: @escaping () -> Void,
        onLoadMore: @escaping () -> Void,
        onOpen: @escaping (FeedItemDTO) -> Void,
        onTouchDown: @escaping (FeedItemDTO) -> Void,
        onViewportChanged: @escaping ([Int]) -> Void,
        onMenuAction: @escaping (FeedItemDTO, VideoCardOverflowAction) -> Void
    ) {
        loadViewIfNeeded()
        self.imageQuality = imageQuality
        self.meta = meta
        self.usesTopTrailingDuration = usesTopTrailingDuration
        configuredColumns = max(1, columns)
        self.scrollState = scrollState
        self.onRefresh = onRefresh
        self.onLoadMore = onLoadMore
        self.onOpen = onOpen
        self.onTouchDown = onTouchDown
        self.onViewportChanged = onViewportChanged
        self.onMenuAction = onMenuAction

        let newFooterState: HomeFeedFooterState? = {
            if isLoading, !items.isEmpty { return .loading }
            if isEnd, !items.isEmpty { return .end }
            return nil
        }()
        let previousFooterState = footerState
        footerState = newFooterState

        var newItems: [FeedStableIdentity: FeedItemDTO] = [:]
        var newModels: [FeedStableIdentity: MediaCardRenderModel] = [:]
        var newIDs: [FeedStableIdentity] = []
        newIDs.reserveCapacity(items.count)
        for item in items {
            let id = FeedStableIdentity(item)
            guard id.isValid, newItems[id] == nil else { continue }
            newItems[id] = item
            newModels[id] = MediaCardRenderModel(
                feed: item,
                imageQuality: imageQuality,
                meta: meta,
                durationPlacement: usesTopTrailingDuration ? .topTrailing : .bottomTrailing
            )
            newIDs.append(id)
        }

        let changedIDs = newIDs.filter { modelByID[$0] != newModels[$0] }
        let structureChanged = orderedIDs != newIDs || previousFooterState != newFooterState
        itemByID = newItems
        modelByID = newModels
        orderedIDs = newIDs

        updateLayoutIfNeeded()
        applySnapshot(structureChanged: structureChanged, changedIDs: changedIDs)

        if !isLoading, collectionView.refreshControl?.isRefreshing == true {
            collectionView.refreshControl?.endRefreshing()
        }

        if lastScrollToTopSignal != scrollToTopSignal {
            lastScrollToTopSignal = scrollToTopSignal
            scrollToTop(animated: true)
        }
    }

    private func configureDataSource() {
        let cardRegistration = UICollectionView.CellRegistration<HomeFeedCardCell, FeedStableIdentity> { [weak self] cell, _, id in
            guard let self,
                  let item = self.itemByID[id],
                  let model = self.modelByID[id] else { return }
            cell.configure(
                item: item,
                model: model,
                targetWidth: self.layoutConfiguration?.cardWidth ?? 180,
                menuAction: { [weak self] action in
                    self?.onMenuAction(item, action)
                }
            )
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

    private func applySnapshot(structureChanged: Bool, changedIDs: [FeedStableIdentity]) {
        guard dataSource != nil else { return }
        if structureChanged {
            visibleIndices.removeAll(keepingCapacity: true)
            onViewportChanged([])
            var snapshot = NSDiffableDataSourceSnapshot<Section, ItemID>()
            snapshot.appendSections([.content])
            snapshot.appendItems(orderedIDs.map(ItemID.card), toSection: .content)
            if let footerState {
                snapshot.appendSections([.footer])
                snapshot.appendItems([.footer(footerState)], toSection: .footer)
            }
            dataSource.apply(snapshot, animatingDifferences: false)
            return
        }

        guard !changedIDs.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        let identifiers = changedIDs.map(ItemID.card).filter { snapshot.indexOfItem($0) != nil }
        if !identifiers.isEmpty {
            snapshot.reconfigureItems(identifiers)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            if sectionIndex == 1 {
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
        let width = max(collectionView.bounds.width, 1)
        let next = HomeFeedGridLayoutMetrics(containerWidth: width, columns: configuredColumns, meta: meta)
        guard next != layoutConfiguration else { return }
        layoutConfiguration = next
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        if !orderedIDs.isEmpty {
            var snapshot = dataSource.snapshot()
            let existingIdentifiers = orderedIDs
                .map(ItemID.card)
                .filter { snapshot.indexOfItem($0) != nil }
            if !existingIdentifiers.isEmpty {
                snapshot.reconfigureItems(existingIdentifiers)
                dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
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
        let indices = indexPaths
            .filter { $0.section == 0 && orderedIDs.indices.contains($0.item) }
            .map(\.item)
        guard !indices.isEmpty else { return }
        let covers = indices.compactMap { itemByID[orderedIDs[$0]]?.cover }
        let width = layoutConfiguration?.cardWidth ?? 180
        CoverImagePrefetcher.shared.prefetch(
            covers,
            targetPointSize: CGSize(width: width, height: (width / VideoCoverView.aspectRatio).rounded()),
            quality: imageQuality
        )
    }
}

private enum HomeFeedFooterState: Hashable {
    case loading
    case end
}

private final class HomeFeedFooterCell: UICollectionViewCell {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.color = IbiliTheme.accentUIColor
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        contentView.addSubview(spinner)
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        label.frame = contentView.bounds.insetBy(dx: 12, dy: 8)
    }

    func configure(_ state: HomeFeedFooterState) {
        switch state {
        case .loading:
            label.text = nil
            spinner.startAnimating()
        case .end:
            spinner.stopAnimating()
            label.text = "已经到底了"
        }
    }
}

private final class HomeFeedCardCell: UICollectionViewCell {
    private let coverImageView = UIImageView()
    private let playBadge = HomeFeedBadgeLabel()
    private let durationBadge = HomeFeedBadgeLabel()
    private let titleLabel = UILabel()
    private let authorIcon = UIImageView()
    private let authorLabel = UILabel()
    private let metaLabel = UILabel()
    private let menuButton = UIButton(type: .system)
    private var imageTask: Task<Void, Never>?
    private var representedURL: URL?
    private var model: MediaCardRenderModel?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let surfaceColor = UIColor.secondarySystemBackground
        isOpaque = true
        contentView.isOpaque = true
        backgroundColor = surfaceColor
        contentView.backgroundColor = surfaceColor
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.masksToBounds = true

        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.backgroundColor = .tertiarySystemFill
        coverImageView.isOpaque = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        authorIcon.image = UIImage(systemName: "person.fill")
        authorIcon.contentMode = .scaleAspectFit
        authorLabel.font = .preferredFont(forTextStyle: .caption1)
        authorLabel.numberOfLines = 1
        authorLabel.lineBreakMode = .byTruncatingTail

        metaLabel.font = .preferredFont(forTextStyle: .caption2)
        metaLabel.textColor = .secondaryLabel
        metaLabel.numberOfLines = 1
        metaLabel.lineBreakMode = .byTruncatingTail

        VideoCardOverflowMenuBuilder.configureButton(menuButton)

        [coverImageView, playBadge, durationBadge, titleLabel, authorIcon, authorLabel, metaLabel, menuButton].forEach {
            contentView.addSubview($0)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        representedURL = nil
        coverImageView.image = nil
        menuButton.menu = nil
        model = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let model else { return }
        let width = contentView.bounds.width
        let coverHeight = (width / VideoCoverView.aspectRatio).rounded()
        coverImageView.frame = CGRect(x: 0, y: 0, width: width, height: coverHeight)

        let badgeInset: CGFloat = 8
        playBadge.sizeToFit()
        durationBadge.sizeToFit()
        let playSize = playBadge.bounds.size
        let durationSize = durationBadge.bounds.size
        playBadge.frame.origin = CGPoint(x: badgeInset, y: coverHeight - badgeInset - playSize.height)
        let durationY = model.durationPlacement == .topTrailing
            ? badgeInset
            : coverHeight - badgeInset - durationSize.height
        durationBadge.frame.origin = CGPoint(x: width - badgeInset - durationSize.width, y: durationY)

        let horizontalInset: CGFloat = 8
        var y = coverHeight + 8
        let textWidth = max(1, width - horizontalInset * 2)
        titleLabel.frame = CGRect(x: horizontalInset, y: y, width: textWidth, height: 38)
        y += 44

        if model.meta.showAuthor {
            let iconSize: CGFloat = 13
            authorIcon.frame = CGRect(x: horizontalInset, y: y + 1, width: iconSize, height: iconSize)
            authorLabel.frame = CGRect(
                x: authorIcon.frame.maxX + 4,
                y: y,
                width: max(1, width - authorIcon.frame.maxX - 4 - 34),
                height: 16
            )
            y += 22
        } else {
            authorIcon.frame = .zero
            authorLabel.frame = .zero
        }

        if !metaLabel.isHidden {
            metaLabel.frame = CGRect(x: horizontalInset, y: y, width: max(1, width - horizontalInset * 2 - 28), height: 15)
        } else {
            metaLabel.frame = .zero
        }
        menuButton.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
        menuButton.center = CGPoint(x: width - 18, y: contentView.bounds.height - 18)
    }

    func configure(
        item: FeedItemDTO,
        model: MediaCardRenderModel,
        targetWidth: CGFloat,
        menuAction: @escaping (VideoCardOverflowAction) -> Void
    ) {
        self.model = model
        titleLabel.text = model.title
        authorLabel.text = model.author
        let authorColor = model.isAuthorFollowed ? IbiliTheme.accentUIColor : UIColor.secondaryLabel
        authorLabel.textColor = authorColor
        authorIcon.tintColor = authorColor
        authorIcon.isHidden = !model.meta.showAuthor
        authorLabel.isHidden = !model.meta.showAuthor

        playBadge.isHidden = !model.meta.showPlay
        playBadge.set(symbol: "play.fill", text: BiliFormat.compactCount(model.play), monospaced: false)
        durationBadge.isHidden = !model.meta.showDuration || model.durationSec <= 0
        durationBadge.set(symbol: nil, text: BiliFormat.duration(model.durationSec), monospaced: true)
        metaLabel.text = Self.metaText(model)
        metaLabel.isHidden = metaLabel.text?.isEmpty != false

        menuButton.menu = VideoCardOverflowMenuBuilder.makeMenu(
            bvid: item.bvid,
            author: item.author,
            ownerMID: item.ownerMID,
            dislikeReasons: item.dislikeReasons,
            feedbackReasons: item.feedbackReasons,
            actionHandler: menuAction
        )

        accessibilityLabel = [model.title, model.author].filter { !$0.isEmpty }.joined(separator: "，")
        accessibilityTraits = .button
        loadImage(model.cover, targetWidth: targetWidth, quality: model.imageQuality)
        setNeedsLayout()
    }

    static func preferredHeight(width: CGFloat, meta: FeedCardMetaConfig) -> CGFloat {
        let coverHeight = (width / VideoCoverView.aspectRatio).rounded()
        var infoHeight: CGFloat = 8 + 38 + 10
        if meta.showAuthor { infoHeight += 22 }
        if meta.showPubdate || meta.stat != .none { infoHeight += 21 }
        return coverHeight + infoHeight
    }

    private static func metaText(_ model: MediaCardRenderModel) -> String {
        var parts: [String] = []
        if model.meta.showPubdate, model.pubdate > 0 {
            parts.append(BiliFormat.relativeDate(model.pubdate))
        }
        switch model.meta.stat {
        case .none:
            break
        case .danmaku:
            parts.append("弹幕 \(BiliFormat.compactCount(model.danmaku))")
        case .like:
            parts.append("点赞 \(BiliFormat.compactCount(model.like))")
        }
        return parts.joined(separator: " · ")
    }

    private func loadImage(_ rawURL: String, targetWidth: CGFloat, quality: Int?) {
        imageTask?.cancel()
        let targetSize = CGSize(width: targetWidth, height: (targetWidth / VideoCoverView.aspectRatio).rounded())
        let resolved = BiliImageURL.resized(rawURL, pointSize: targetSize, quality: quality)
        guard let url = URL(string: resolved) else {
            representedURL = nil
            coverImageView.image = nil
            return
        }
        if representedURL == url, coverImageView.image != nil { return }
        representedURL = url
        coverImageView.image = ImageCache.shared.image(for: url)
        guard coverImageView.image == nil else { return }
        let maxPixelDimension = max(targetSize.width, targetSize.height) * UIScreen.main.scale
        imageTask = Task { [weak self] in
            let image = await ImagePipeline.shared.image(for: url, maxPixelDimension: maxPixelDimension)
            guard !Task.isCancelled,
                  let self,
                  self.representedURL == url else { return }
            self.coverImageView.image = image
        }
    }
}

private final class HomeFeedBadgeLabel: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .systemFont(ofSize: 12, weight: .semibold)
        textColor = .white
        backgroundColor = UIColor.black.withAlphaComponent(0.62)
        layer.cornerRadius = 11
        layer.masksToBounds = true
        textAlignment = .center
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let base = super.sizeThatFits(size)
        return CGSize(width: base.width + 12, height: 22)
    }

    func set(symbol: String?, text: String, monospaced: Bool) {
        if monospaced {
            font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        } else {
            font = .systemFont(ofSize: 12, weight: .semibold)
        }
        if let symbol, let image = UIImage(systemName: symbol)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -1, width: 11, height: 11)
            let value = NSMutableAttributedString(attachment: attachment)
            value.append(NSAttributedString(string: " \(text)", attributes: [.foregroundColor: UIColor.white, .font: font as Any]))
            attributedText = value
        } else {
            attributedText = nil
            self.text = text
        }
    }
}
