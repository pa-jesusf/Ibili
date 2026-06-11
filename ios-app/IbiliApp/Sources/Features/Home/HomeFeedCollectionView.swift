import SwiftUI
import UIKit

enum HomeFeedCardAction {
    case copyBVID
    case watchLater
    case visitOwner
    case plainDislike
    case undoDislike
    case dislikeReason(FeedDislikeReasonDTO)
    case feedbackReason(FeedDislikeReasonDTO)
    case blockOwner
}

struct HomeFeedCollectionView: UIViewRepresentable {
    let items: [FeedItemDTO]
    let columns: Int
    let imageQuality: Int?
    let showsDurationAtTopTrailing: Bool
    let meta: FeedCardMetaConfig
    let scrollToTopSignal: Int
    let isRefreshing: Bool
    let onTap: (FeedItemDTO) -> Void
    let onTouchDown: (FeedItemDTO) -> Void
    let onAction: (FeedItemDTO, HomeFeedCardAction) -> Void
    let onRefresh: () -> Void
    let onReachEnd: () -> Void
    let onVisibleItemsChange: ([FeedItemDTO]) -> Void
    let onScrollOffsetChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = context.coordinator
        collectionView.dataSource = context.coordinator
        collectionView.prefetchDataSource = context.coordinator
        collectionView.register(HomeFeedCardCell.self, forCellWithReuseIdentifier: HomeFeedCardCell.reuseID)
        collectionView.register(
            HomeFeedHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: HomeFeedHeaderView.reuseID
        )
        collectionView.showsVerticalScrollIndicator = true
        let refreshControl = UIRefreshControl()
        refreshControl.tintColor = IbiliTheme.accentUIColor
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.refreshPulled), for: .valueChanged)
        collectionView.refreshControl = refreshControl
        context.coordinator.collectionView = collectionView
        context.coordinator.applyLayout(to: collectionView)
        context.coordinator.apply(items: items)
        if !isRefreshing {
            collectionView.refreshControl?.endRefreshing()
        }
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyLayout(to: collectionView)
        context.coordinator.apply(items: items)
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

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UICollectionViewDataSourcePrefetching {
        var parent: HomeFeedCollectionView
        weak var collectionView: UICollectionView?
        var lastScrollToTopSignal = 0

        private var currentItems: [FeedItemDTO] = []
        private var currentIDs: [FeedStableIdentity] = []
        private var lastLayoutWidth: CGFloat = 0
        private var visibleSettleTask: Task<Void, Never>?

        init(parent: HomeFeedCollectionView) {
            self.parent = parent
        }

        func apply(items: [FeedItemDTO]) {
            let newIDs = items.map(FeedStableIdentity.init)
            guard newIDs != currentIDs else { return }
            guard let collectionView else {
                currentItems = items
                currentIDs = newIDs
                return
            }

            if currentIDs.count < newIDs.count,
               Array(newIDs.prefix(currentIDs.count)) == currentIDs {
                let start = currentIDs.count
                currentItems = items
                currentIDs = newIDs
                let inserted = (start..<newIDs.count).map { IndexPath(item: $0, section: 0) }
                collectionView.performBatchUpdates {
                    collectionView.insertItems(at: inserted)
                }
            } else {
                currentItems = items
                currentIDs = newIDs
                collectionView.reloadData()
            }
            scheduleVisibleItemsReport()
        }

        func applyLayout(to collectionView: UICollectionView) {
            let width = max(collectionView.bounds.width, 1)
            guard abs(width - lastLayoutWidth) > 0.5,
                  let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }
            lastLayoutWidth = width
            let metrics = layoutMetrics(containerWidth: width)
            layout.sectionInset = UIEdgeInsets(
                top: 0,
                left: metrics.horizontalPadding,
                bottom: 12,
                right: metrics.horizontalPadding
            )
            layout.minimumInteritemSpacing = metrics.spacing
            layout.minimumLineSpacing = metrics.rowSpacing
            layout.itemSize = CGSize(width: metrics.cardWidth, height: metrics.cardHeight)
            layout.headerReferenceSize = CGSize(
                width: width,
                height: FeedSegmentedHeaderMetrics.expandedHeight
            )
            layout.invalidateLayout()
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            currentItems.count
        }

        func collectionView(_ collectionView: UICollectionView,
                            cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: HomeFeedCardCell.reuseID,
                for: indexPath
            ) as! HomeFeedCardCell
            guard currentItems.indices.contains(indexPath.item) else { return cell }
            let item = currentItems[indexPath.item]
            let metrics = layoutMetrics(containerWidth: max(collectionView.bounds.width, 1))
            cell.configure(
                item: item,
                width: metrics.cardWidth,
                imageQuality: parent.imageQuality,
                showsDurationAtTopTrailing: parent.showsDurationAtTopTrailing,
                meta: parent.meta,
                actionHandler: { [weak self] action in
                    self?.parent.onAction(item, action)
                }
            )
            return cell
        }

        func collectionView(_ collectionView: UICollectionView,
                            viewForSupplementaryElementOfKind kind: String,
                            at indexPath: IndexPath) -> UICollectionReusableView {
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: HomeFeedHeaderView.reuseID,
                for: indexPath
            ) as! HomeFeedHeaderView
            view.configure(title: "主页")
            return view
        }

        func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
            guard currentItems.indices.contains(indexPath.item) else { return }
            parent.onTouchDown(currentItems[indexPath.item])
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard currentItems.indices.contains(indexPath.item) else { return }
            parent.onTap(currentItems[indexPath.item])
        }

        func collectionView(_ collectionView: UICollectionView,
                            willDisplay cell: UICollectionViewCell,
                            forItemAt indexPath: IndexPath) {
            if indexPath.item >= max(0, currentItems.count - 4) {
                parent.onReachEnd()
            }
            scheduleVisibleItemsReport()
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let urls = indexPaths.compactMap { indexPath -> String? in
                guard currentItems.indices.contains(indexPath.item) else { return nil }
                return currentItems[indexPath.item].cover
            }
            let metrics = layoutMetrics(containerWidth: max(collectionView.bounds.width, 1))
            CoverImagePrefetcher.shared.prefetch(
                urls,
                targetPointSize: CGSize(width: metrics.cardWidth, height: metrics.coverHeight),
                quality: parent.imageQuality
            )
        }

        func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {}

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let offset = scrollView.contentOffset.y
            parent.onScrollOffsetChange(offset)
            scheduleVisibleItemsReport()
        }

        func scrollToTop(_ collectionView: UICollectionView) {
            collectionView.layer.removeAllAnimations()
            let target = CGPoint(x: 0, y: -collectionView.adjustedContentInset.top)
            collectionView.setContentOffset(target, animated: false)
            parent.onScrollOffsetChange(0)
            scheduleVisibleItemsReport()
        }

        @objc func refreshPulled() {
            parent.onRefresh()
        }

        private func scheduleVisibleItemsReport() {
            visibleSettleTask?.cancel()
            visibleSettleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                await MainActor.run {
                    self?.reportVisibleItems()
                }
            }
        }

        private func reportVisibleItems() {
            guard let collectionView else { return }
            let visible = collectionView.indexPathsForVisibleItems
                .sorted()
                .compactMap { currentItems.indices.contains($0.item) ? currentItems[$0.item] : nil }
            parent.onVisibleItemsChange(visible)
        }

        private func layoutMetrics(containerWidth: CGFloat) -> HomeFeedLayoutMetrics {
            HomeFeedLayoutMetrics(
                containerWidth: containerWidth,
                columns: parent.columns,
                meta: parent.meta
            )
        }
    }
}

private struct HomeFeedLayoutMetrics {
    let horizontalPadding: CGFloat = 12
    let spacing: CGFloat = 12
    let rowSpacing: CGFloat = 14
    let cardWidth: CGFloat
    let coverHeight: CGFloat
    let cardHeight: CGFloat

    init(containerWidth: CGFloat, columns: Int, meta: FeedCardMetaConfig) {
        let clampedColumns = max(1, columns)
        let totalSpacing = spacing * CGFloat(clampedColumns - 1) + horizontalPadding * 2
        cardWidth = max(1, floor((containerWidth - totalSpacing) / CGFloat(clampedColumns)))
        coverHeight = (cardWidth / VideoCoverView.aspectRatio).rounded()
        let infoHeight: CGFloat = meta.showAuthor ? 82 : 60
        cardHeight = coverHeight + infoHeight
    }
}

private final class HomeFeedHeaderView: UICollectionReusableView {
    static let reuseID = "HomeFeedHeaderView"

    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
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

private final class HomeFeedCardCell: UICollectionViewCell {
    static let reuseID = "HomeFeedCardCell"

    private let coverView = UIImageView()
    private let titleLabel = UILabel()
    private let authorLabel = UILabel()
    private let metaLabel = UILabel()
    private let playChip = HomeFeedOverlayChip()
    private let durationChip = HomeFeedOverlayChip()
    private let menuButton = UIButton(type: .system)

    private var imageTask: Task<Void, Never>?
    private var representedCoverURL: URL?
    private var actionHandler: ((HomeFeedCardAction) -> Void)?
    private var durationAtTopTrailing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 10
        contentView.layer.cornerCurve = .continuous
        contentView.layer.masksToBounds = true

        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.backgroundColor = UIColor.tertiarySystemFill

        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2

        authorLabel.font = .preferredFont(forTextStyle: .caption1)
        authorLabel.textColor = .secondaryLabel
        authorLabel.numberOfLines = 1

        metaLabel.font = .preferredFont(forTextStyle: .caption2)
        metaLabel.textColor = .secondaryLabel
        metaLabel.numberOfLines = 1

        menuButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        menuButton.tintColor = .secondaryLabel
        menuButton.showsMenuAsPrimaryAction = true

        [coverView, titleLabel, authorLabel, metaLabel, playChip, durationChip, menuButton].forEach {
            contentView.addSubview($0)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        representedCoverURL = nil
        coverView.image = nil
        actionHandler = nil
        menuButton.menu = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let coverHeight = (width / VideoCoverView.aspectRatio).rounded()
        coverView.frame = CGRect(x: 0, y: 0, width: width, height: coverHeight)

        titleLabel.frame = CGRect(x: 8, y: coverHeight + 8, width: width - 16, height: 38)
        authorLabel.frame = CGRect(x: 8, y: titleLabel.frame.maxY + 5, width: width - 42, height: 18)
        metaLabel.frame = CGRect(x: 8, y: authorLabel.frame.maxY + 2, width: width - 42, height: 16)
        menuButton.frame = CGRect(x: width - 32, y: bounds.height - 34, width: 30, height: 30)

        let playSize = playChip.intrinsicContentSize
        playChip.frame = CGRect(x: 8, y: coverHeight - playSize.height - 8, width: playSize.width, height: playSize.height)
        let durationSize = durationChip.intrinsicContentSize
        let durationY: CGFloat = durationAtTopTrailing ? 8 : coverHeight - durationSize.height - 8
        durationChip.frame = CGRect(
            x: width - durationSize.width - 8,
            y: durationY,
            width: durationSize.width,
            height: durationSize.height
        )
    }

    func configure(item: FeedItemDTO,
                   width: CGFloat,
                   imageQuality: Int?,
                   showsDurationAtTopTrailing: Bool,
                   meta: FeedCardMetaConfig,
                   actionHandler: @escaping (HomeFeedCardAction) -> Void) {
        self.actionHandler = actionHandler
        durationAtTopTrailing = showsDurationAtTopTrailing
        titleLabel.text = item.title
        authorLabel.text = item.author
        authorLabel.isHidden = !meta.showAuthor
        authorLabel.textColor = item.isFollowed ? IbiliTheme.accentUIColor : .secondaryLabel

        if meta.stat == .none {
            metaLabel.isHidden = true
        } else {
            metaLabel.isHidden = false
            let value = meta.stat == .danmaku ? item.danmaku : 0
            metaLabel.text = "\(BiliFormat.compactCount(value))"
        }

        playChip.configure(systemImage: "play.fill", text: BiliFormat.compactCount(item.play))
        playChip.isHidden = !meta.showPlay
        durationChip.configure(systemImage: nil, text: BiliFormat.duration(item.durationSec))
        durationChip.isHidden = !meta.showDuration || item.durationSec <= 0
        if showsDurationAtTopTrailing {
            setNeedsLayout()
        }
        menuButton.menu = makeMenu(item: item)
        loadCover(item.cover, width: width, imageQuality: imageQuality)
    }

    private func loadCover(_ rawURL: String, width: CGFloat, imageQuality: Int?) {
        let height = (width / VideoCoverView.aspectRatio).rounded()
        let resolved = BiliImageURL.resized(
            rawURL,
            pointSize: CGSize(width: width, height: height),
            quality: imageQuality
        )
        guard let url = URL(string: resolved) else { return }
        representedCoverURL = url
        imageTask?.cancel()
        let maxPixelDimension = max(width, height) * UIScreen.main.scale
        imageTask = Task { [weak self, url] in
            let image = await ImagePipeline.shared.image(
                for: url,
                maxPixelDimension: maxPixelDimension
            )
            await MainActor.run {
                guard let self, self.representedCoverURL == url else { return }
                self.coverView.image = image
            }
        }
    }

    private func makeMenu(item: FeedItemDTO) -> UIMenu {
        let copy = UIAction(title: item.bvid.isEmpty ? "复制 BV 号" : item.bvid,
                            image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            self?.actionHandler?(.copyBVID)
        }
        let watchLater = UIAction(title: "稍后再看", image: UIImage(systemName: "clock")) { [weak self] _ in
            self?.actionHandler?(.watchLater)
        }
        let visit = UIAction(title: "访问：\(item.author)", image: UIImage(systemName: "person.crop.circle")) { [weak self] _ in
            self?.actionHandler?(.visitOwner)
        }
        let dislikeChildren = dislikeMenuItems(item: item)
        let dislike = UIMenu(
            title: "不感兴趣",
            image: UIImage(systemName: "hand.thumbsdown"),
            children: dislikeChildren
        )
        let block = UIAction(title: "拉黑：\(item.author)",
                             image: UIImage(systemName: "nosign"),
                             attributes: .destructive) { [weak self] _ in
            self?.actionHandler?(.blockOwner)
        }
        return UIMenu(children: [copy, watchLater, visit, dislike, block])
    }

    private func dislikeMenuItems(item: FeedItemDTO) -> [UIMenuElement] {
        var elements: [UIMenuElement] = []
        let reasonActions = item.dislikeReasons.map { reason in
            UIAction(title: reason.name, image: UIImage(systemName: "hand.thumbsdown")) { [weak self] _ in
                self?.actionHandler?(.dislikeReason(reason))
            }
        }
        let feedbackActions = item.feedbackReasons.map { reason in
            UIAction(title: reason.name, image: UIImage(systemName: "exclamationmark.bubble")) { [weak self] _ in
                self?.actionHandler?(.feedbackReason(reason))
            }
        }
        elements.append(contentsOf: reasonActions)
        elements.append(contentsOf: feedbackActions)
        if elements.isEmpty {
            elements.append(UIAction(title: "点踩", image: UIImage(systemName: "hand.thumbsdown")) { [weak self] _ in
                self?.actionHandler?(.plainDislike)
            })
        }
        elements.append(UIAction(title: "撤销点踩", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
            self?.actionHandler?(.undoDislike)
        })
        return elements
    }
}

private final class HomeFeedOverlayChip: UIView {
    private let iconView = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.58)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        addSubview(iconView)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: CGSize {
        let labelSize = label.intrinsicContentSize
        let hasIcon = iconView.image != nil
        return CGSize(
            width: labelSize.width + (hasIcon ? 15 : 0) + 10,
            height: 18
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let hasIcon = iconView.image != nil
        if hasIcon {
            iconView.frame = CGRect(x: 5, y: 3, width: 12, height: 12)
            label.frame = CGRect(x: 19, y: 1, width: bounds.width - 24, height: 16)
        } else {
            label.frame = bounds.insetBy(dx: 5, dy: 1)
        }
    }

    func configure(systemImage: String?, text: String) {
        iconView.image = systemImage.flatMap { UIImage(systemName: $0) }
        label.text = text
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
}
