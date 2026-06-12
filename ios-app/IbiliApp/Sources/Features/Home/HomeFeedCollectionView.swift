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

enum HomeFeedCardContent: Hashable {
    case video(FeedItemDTO)
    case live(LiveFeedItemDTO)

    enum Kind {
        case video
        case live
    }

    var kind: Kind {
        switch self {
        case .video:
            return .video
        case .live:
            return .live
        }
    }

    var identity: FeedStableIdentity {
        switch self {
        case .video(let item):
            return FeedStableIdentity(item)
        case .live(let item):
            return FeedStableIdentity(item)
        }
    }

    var cover: String {
        switch self {
        case .video(let item):
            return item.cover
        case .live(let item):
            return item.systemCover.isEmpty ? item.cover : item.systemCover
        }
    }
}

struct HomeFeedCollectionView: UIViewRepresentable {
    let items: [HomeFeedCardContent]
    let columns: Int
    let imageQuality: Int?
    let showsDurationAtTopTrailing: Bool
    let meta: FeedCardMetaConfig
    let scrollToTopSignal: Int
    let isRefreshing: Bool
    let onTap: (HomeFeedCardContent) -> Void
    let onTouchDown: (HomeFeedCardContent) -> Void
    let onAction: (FeedItemDTO, HomeFeedCardAction) -> Void
    let onRefresh: () -> Void
    let onReachEnd: () -> Void
    let onVisibleItemsChange: ([FeedItemDTO]) -> Void
    let onScrollOffsetChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
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

        private var currentItems: [HomeFeedCardContent] = []
        private var currentIDs: [FeedStableIdentity] = []
        private var currentContentKind: HomeFeedCardContent.Kind?
        private var lastLayoutWidth: CGFloat = 0
        private var lastSafeAreaInsets: UIEdgeInsets = .zero
        private var visibleSettleTask: Task<Void, Never>?
        private var collapseState = FeedScrollCollapseState()
        private var currentHeaderProgress: CGFloat = 0

        init(parent: HomeFeedCollectionView) {
            self.parent = parent
        }

        func apply(items: [HomeFeedCardContent]) {
            let newIDs = items.map(\.identity)
            let newKind = items.first?.kind
            let didChangeKind = currentContentKind != nil && currentContentKind != newKind
            guard newIDs != currentIDs else { return }
            guard let collectionView else {
                currentItems = items
                currentIDs = newIDs
                currentContentKind = newKind
                return
            }
            currentContentKind = newKind

            if currentIDs.count < newIDs.count,
               Array(newIDs.prefix(currentIDs.count)) == currentIDs,
               !didChangeKind,
               collectionView.window != nil,
               collectionView.numberOfSections > 0,
               collectionView.numberOfItems(inSection: 0) == currentIDs.count {
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
            let safeInsets = resolvedSafeAreaInsets(for: collectionView)
            guard abs(width - lastLayoutWidth) > 0.5 || safeInsets != lastSafeAreaInsets,
                  let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }
            lastLayoutWidth = width
            lastSafeAreaInsets = safeInsets
            let metrics = layoutMetrics(containerWidth: width)
            layout.sectionInset = UIEdgeInsets(
                top: 0,
                left: metrics.horizontalPadding,
                bottom: max(16, safeInsets.bottom + 16),
                right: metrics.horizontalPadding
            )
            layout.minimumInteritemSpacing = metrics.spacing
            layout.minimumLineSpacing = metrics.rowSpacing
            layout.itemSize = CGSize(width: metrics.cardWidth, height: metrics.cardHeight)
            layout.headerReferenceSize = CGSize(
                width: width,
                height: safeInsets.top + FeedSegmentedHeaderMetrics.expandedHeight
            )
            layout.invalidateLayout()
        }

        private func resolvedSafeAreaInsets(for collectionView: UICollectionView) -> UIEdgeInsets {
            if let window = collectionView.window {
                return window.safeAreaInsets
            }
            return collectionView.safeAreaInsets
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
                    guard case .video(let feedItem) = item else { return }
                    self?.parent.onAction(feedItem, action)
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
            view.setCollapseProgress(currentHeaderProgress)
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
            let collapse = collapseState.update(rawOffset: offset)
            currentHeaderProgress = collapse.headerProgress
            updateVisibleHeader(collapseProgress: collapse.headerProgress)
            parent.onScrollOffsetChange(offset)
            scheduleVisibleItemsReport()
        }

        func scrollToTop(_ collectionView: UICollectionView) {
            collectionView.layer.removeAllAnimations()
            let target = CGPoint(x: 0, y: -collectionView.adjustedContentInset.top)
            collectionView.setContentOffset(target, animated: false)
            collapseState.reset()
            currentHeaderProgress = 0
            updateVisibleHeader(collapseProgress: 0)
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
                .compactMap { indexPath -> FeedItemDTO? in
                    guard currentItems.indices.contains(indexPath.item),
                          case .video(let item) = currentItems[indexPath.item] else { return nil }
                    return item
                }
            parent.onVisibleItemsChange(visible)
        }

        private func layoutMetrics(containerWidth: CGFloat) -> HomeFeedLayoutMetrics {
            HomeFeedLayoutMetrics(
                containerWidth: containerWidth,
                columns: parent.columns,
                meta: parent.meta
            )
        }

        private func updateVisibleHeader(collapseProgress: CGFloat) {
            guard let collectionView else { return }
            collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
                .compactMap { $0 as? HomeFeedHeaderView }
                .forEach { $0.setCollapseProgress(collapseProgress) }
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

    private let gradientView = FeedCollectionHeaderGradientView()
    private let titleLabel = UILabel()
    private var collapseProgress: CGFloat = 0

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
        let topInset = resolvedSafeAreaTopInset()
        let p = min(1, max(0, collapseProgress))
        let titleSize = 34 - p * 17
        titleLabel.font = .systemFont(ofSize: titleSize, weight: p > 0.5 ? .semibold : .bold)
        gradientView.frame = CGRect(
            x: 0,
            y: -topInset - 24,
            width: bounds.width,
            height: topInset + FeedSegmentedHeaderMetrics.expandedHeight + 44
        )
        titleLabel.frame = CGRect(
            x: 16,
            y: topInset + 52 - p * 35,
            width: bounds.width - 32,
            height: 40
        )
    }

    func configure(title: String) {
        titleLabel.text = title
        setNeedsLayout()
    }

    func setCollapseProgress(_ progress: CGFloat) {
        let clamped = min(1, max(0, progress))
        guard abs(clamped - collapseProgress) > 0.01 else { return }
        collapseProgress = clamped
        setNeedsLayout()
    }

    private func resolvedSafeAreaTopInset() -> CGFloat {
        if let window {
            return window.safeAreaInsets.top
        }
        if let superview {
            return superview.safeAreaInsets.top
        }
        return safeAreaInsets.top
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
        backgroundColor = .clear
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

        VideoCardOverflowMenuBuilder.configureButton(menuButton)

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
        titleLabel.text = nil
        authorLabel.attributedText = nil
        metaLabel.attributedText = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let coverHeight = (width / VideoCoverView.aspectRatio).rounded()
        coverView.frame = CGRect(x: 0, y: 0, width: width, height: coverHeight)

        titleLabel.frame = CGRect(x: 8, y: coverHeight + 8, width: width - 16, height: 38)
        authorLabel.frame = CGRect(x: 8, y: titleLabel.frame.maxY + 5, width: width - 42, height: 18)
        metaLabel.frame = CGRect(x: 8, y: authorLabel.frame.maxY + 2, width: width - 42, height: 16)
        menuButton.frame = CGRect(x: width - 36, y: bounds.height - 38, width: 32, height: 32)

        let playSize = playChip.intrinsicContentSize
        let durationSize = durationChip.intrinsicContentSize
        let durationY: CGFloat = durationAtTopTrailing ? 8 : coverHeight - durationSize.height - 8
        let durationFrame = CGRect(
            x: width - min(durationSize.width, width - 16) - 8,
            y: durationY,
            width: min(durationSize.width, width - 16),
            height: durationSize.height
        )
        durationChip.frame = durationFrame
        let maxPlayWidth = durationChip.isHidden
            ? width - 16
            : max(32, durationFrame.minX - 16)
        playChip.frame = CGRect(
            x: 8,
            y: coverHeight - playSize.height - 8,
            width: min(playSize.width, maxPlayWidth),
            height: playSize.height
        )
    }

    func configure(item: FeedItemDTO,
                   width: CGFloat,
                   imageQuality: Int?,
                   showsDurationAtTopTrailing: Bool,
                   meta: FeedCardMetaConfig,
                   actionHandler: @escaping (HomeFeedCardAction) -> Void) {
        configure(
            item: .video(item),
            width: width,
            imageQuality: imageQuality,
            showsDurationAtTopTrailing: showsDurationAtTopTrailing,
            meta: meta,
            actionHandler: actionHandler
        )
    }

    func configure(item: HomeFeedCardContent,
                   width: CGFloat,
                   imageQuality: Int?,
                   showsDurationAtTopTrailing: Bool,
                   meta: FeedCardMetaConfig,
                   actionHandler: @escaping (HomeFeedCardAction) -> Void) {
        self.actionHandler = actionHandler
        durationAtTopTrailing = showsDurationAtTopTrailing
        let display = displayModel(for: item, meta: meta)
        titleLabel.text = display.title
        authorLabel.attributedText = authorText(display.author, isFollowed: display.isFollowed)
        authorLabel.isHidden = !display.showsAuthor

        if display.metaText.length == 0 {
            metaLabel.isHidden = true
        } else {
            metaLabel.isHidden = false
            metaLabel.attributedText = display.metaText
        }

        playChip.configure(systemImage: display.leadingChipIcon, text: display.leadingChipText)
        playChip.isHidden = display.leadingChipText.isEmpty
        durationChip.configure(systemImage: nil, text: display.trailingChipText, isMonospaced: display.trailingChipIsMonospaced)
        durationChip.isHidden = display.trailingChipText.isEmpty
        if showsDurationAtTopTrailing {
            setNeedsLayout()
        }
        switch item {
        case .video(let feedItem):
            menuButton.isHidden = false
            menuButton.menu = makeMenu(item: feedItem)
        case .live:
            menuButton.isHidden = true
            menuButton.menu = nil
        }
        loadCover(display.cover, width: width, imageQuality: imageQuality)
    }

    private struct DisplayModel {
        let title: String
        let cover: String
        let author: String
        let isFollowed: Bool
        let showsAuthor: Bool
        let leadingChipIcon: String?
        let leadingChipText: String
        let trailingChipText: String
        let trailingChipIsMonospaced: Bool
        let metaText: NSAttributedString
    }

    private func displayModel(for item: HomeFeedCardContent, meta: FeedCardMetaConfig) -> DisplayModel {
        switch item {
        case .video(let video):
            let model = MediaCardRenderModel(
                feed: video,
                imageQuality: nil,
                meta: meta,
                durationPlacement: durationAtTopTrailing ? .topTrailing : .bottomTrailing
            )
            let metaString: String
            switch meta.stat {
            case .none:
                metaString = ""
            case .danmaku:
                metaString = BiliFormat.compactCount(model.danmaku)
            case .like:
                metaString = "0"
            }
            return DisplayModel(
                title: model.title,
                cover: model.cover,
                author: model.author,
                isFollowed: model.isAuthorFollowed,
                showsAuthor: meta.showAuthor,
                leadingChipIcon: "play.fill",
                leadingChipText: meta.showPlay ? BiliFormat.compactCount(model.play) : "",
                trailingChipText: meta.showDuration && model.durationSec > 0 ? BiliFormat.duration(model.durationSec) : "",
                trailingChipIsMonospaced: true,
                metaText: metaText(metaString, systemImage: meta.stat.systemImage)
            )
        case .live(let live):
            let cover = live.systemCover.isEmpty ? live.cover : live.systemCover
            let watched = live.watchedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let area = live.areaName.trimmingCharacters(in: .whitespacesAndNewlines)
            return DisplayModel(
                title: live.title,
                cover: cover,
                author: live.uname,
                isFollowed: live.isFollowed,
                showsAuthor: meta.showAuthor,
                leadingChipIcon: "dot.radiowaves.left.and.right",
                leadingChipText: watched.isEmpty ? "直播中" : watched,
                trailingChipText: area,
                trailingChipIsMonospaced: false,
                metaText: NSAttributedString(string: "")
            )
        }
    }

    private func authorText(_ text: String, isFollowed: Bool) -> NSAttributedString {
        let color = isFollowed ? IbiliTheme.accentUIColor : UIColor.secondaryLabel
        let result = NSMutableAttributedString()
        let symbol = NSTextAttachment()
        let configuration = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        symbol.image = UIImage(systemName: "person.fill", withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        result.append(NSAttributedString(attachment: symbol))
        result.append(NSAttributedString(string: " \(text)", attributes: [
            .foregroundColor: color,
            .font: UIFont.preferredFont(forTextStyle: .caption1),
        ]))
        return result
    }

    private func metaText(_ text: String, systemImage: String) -> NSAttributedString {
        guard !text.isEmpty else { return NSAttributedString(string: "") }
        let result = NSMutableAttributedString()
        if !systemImage.isEmpty {
            let symbol = NSTextAttachment()
            let configuration = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            symbol.image = UIImage(systemName: systemImage, withConfiguration: configuration)?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            result.append(NSAttributedString(attachment: symbol))
            result.append(NSAttributedString(string: " "))
        }
        result.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: UIColor.secondaryLabel,
            .font: UIFont.preferredFont(forTextStyle: .caption2),
        ]))
        return result
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
        VideoCardOverflowMenuBuilder.makeMenu(
            bvid: item.bvid,
            author: item.author,
            ownerMID: item.ownerMID,
            dislikeReasons: item.dislikeReasons,
            feedbackReasons: item.feedbackReasons
        ) { [weak self] action in
            switch action {
            case .copyBVID:
                self?.actionHandler?(.copyBVID)
            case .watchLater:
                self?.actionHandler?(.watchLater)
            case .visitOwner:
                self?.actionHandler?(.visitOwner)
            case .plainDislike:
                self?.actionHandler?(.plainDislike)
            case .undoDislike:
                self?.actionHandler?(.undoDislike)
            case .dislikeReason(let reason):
                self?.actionHandler?(.dislikeReason(reason))
            case .feedbackReason(let reason):
                self?.actionHandler?(.feedbackReason(reason))
            case .blockOwner:
                self?.actionHandler?(.blockOwner)
            }
        }
    }
}

private final class HomeFeedOverlayChip: UIView {
    private let iconView = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.68)
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        label.textColor = .white
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
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
            width: labelSize.width + (hasIcon ? 16 : 0) + 12,
            height: 19
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let hasIcon = iconView.image != nil
        if hasIcon {
            iconView.frame = CGRect(x: 6, y: 3.5, width: 12, height: 12)
            label.frame = CGRect(x: 22, y: 1.5, width: bounds.width - 28, height: 16)
        } else {
            label.frame = bounds.insetBy(dx: 6, dy: 1.5)
        }
    }

    func configure(systemImage: String?, text: String, isMonospaced: Bool = false) {
        iconView.image = systemImage.flatMap { UIImage(systemName: $0) }
        label.text = text
        label.font = isMonospaced
            ? .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            : .systemFont(ofSize: 11, weight: .semibold)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
}
