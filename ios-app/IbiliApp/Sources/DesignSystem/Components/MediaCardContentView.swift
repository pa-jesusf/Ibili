import UIKit

final class MediaCardContentView: UIView {
    private let coverImageView = UIImageView()
    private let backdropImageView = UIImageView()
    private let durationBadge = MediaCardDurationLabel()
    private let titleLabel = UILabel()
    private let authorIcon = UIImageView()
    private let authorLabel = UILabel()
    private let metaLabel = UILabel()
    private let publicationMetaLabel = UILabel()
    private let menuButton = UIButton(type: .system)
    private let liveBadge = UILabel()
    private let summaryLabel = UILabel()
    private let secondaryMetaLabel = UILabel()
    private var imageTask: Task<Void, Never>?
    private var representedRequest: ImageRequestKey?
    private var representedBackdrop: ExtendedCoverBackdrop.Configuration?
    private var model: MediaCardRenderModel?
    private var configuredWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        let surfaceColor = UIColor.secondarySystemBackground
        isOpaque = true
        backgroundColor = surfaceColor
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1 / UIScreen.main.scale

        coverImageView.contentMode = .scaleAspectFit
        coverImageView.clipsToBounds = true
        coverImageView.backgroundColor = .tertiarySystemFill
        coverImageView.isOpaque = true
        backdropImageView.contentMode = .scaleToFill
        backdropImageView.clipsToBounds = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        authorIcon.image = UIImage(systemName: "person.crop.circle")
        authorIcon.contentMode = .scaleAspectFit
        authorLabel.font = .preferredFont(forTextStyle: .caption1)
        authorLabel.numberOfLines = 1
        authorLabel.lineBreakMode = .byTruncatingTail

        metaLabel.font = .preferredFont(forTextStyle: .caption2)
        metaLabel.textColor = .secondaryLabel
        metaLabel.numberOfLines = 1
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.adjustsFontSizeToFitWidth = true
        metaLabel.minimumScaleFactor = 0.9
        publicationMetaLabel.font = .preferredFont(forTextStyle: .caption2)
        publicationMetaLabel.textColor = .secondaryLabel
        publicationMetaLabel.numberOfLines = 1
        publicationMetaLabel.lineBreakMode = .byTruncatingTail
        durationBadge.backgroundColor = .clear
        durationBadge.textColor = .secondaryLabel
        durationBadge.adjustsFontSizeToFitWidth = true
        durationBadge.minimumScaleFactor = 0.85

        VideoCardOverflowMenuBuilder.configureButton(menuButton)
        liveBadge.text = "LIVE"
        liveBadge.font = .systemFont(ofSize: 10, weight: .bold)
        liveBadge.textColor = .white
        liveBadge.textAlignment = .center
        liveBadge.backgroundColor = IbiliTheme.accentUIColor
        liveBadge.layer.cornerRadius = 10
        liveBadge.clipsToBounds = true
        summaryLabel.font = .preferredFont(forTextStyle: .caption1)
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.numberOfLines = 2
        secondaryMetaLabel.font = .preferredFont(forTextStyle: .caption2)
        secondaryMetaLabel.textColor = .secondaryLabel

        [coverImageView, backdropImageView, durationBadge, titleLabel, authorIcon, authorLabel, metaLabel, publicationMetaLabel, menuButton, liveBadge, summaryLabel, secondaryMetaLabel].forEach {
            addSubview($0)
        }
        updateSurfaceAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { imageTask?.cancel() }

    func reset() {
        imageTask?.cancel()
        imageTask = nil
        representedRequest = nil
        representedBackdrop = nil
        coverImageView.image = nil
        backdropImageView.image = nil
        menuButton.menu = nil
        model = nil
        configuredWidth = 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let model else { return }
        let width = bounds.width
        let layout = Self.layout(width: width, model: model)
        layer.cornerRadius = layout.cornerRadius
        coverImageView.frame = layout.coverFrame
        liveBadge.frame = CGRect(x: 8, y: 8, width: 40, height: 20)
        backdropImageView.frame = layout.extendedBackdropFrame

        durationBadge.sizeToFit()
        let durationWidth = min(durationBadge.bounds.width, layout.durationAvailableWidth)
        durationBadge.frame = CGRect(x: width - layout.durationTrailingInset - durationWidth,
                                     y: layout.durationY, width: durationWidth, height: 22)

        titleLabel.font = .systemFont(ofSize: layout.titleFontSize, weight: .semibold)
        titleLabel.frame = layout.titleFrame
        summaryLabel.frame = layout.summaryFrame
        secondaryMetaLabel.frame = layout.secondaryMetadataFrame
        publicationMetaLabel.numberOfLines = layout.publicationMetadataLines
        publicationMetaLabel.frame = layout.pubdateFrame

        if model.meta.showAuthor {
            let iconSize: CGFloat = 13
            authorIcon.frame = CGRect(x: layout.horizontalInset, y: layout.authorFrame.minY + 1,
                                      width: iconSize, height: iconSize)
            authorLabel.frame = layout.authorFrame
        } else {
            authorIcon.frame = .zero
            authorLabel.frame = .zero
        }

        if !metaLabel.isHidden {
            metaLabel.numberOfLines = width < 150 ? layout.compactMetadataLines : 1
            metaLabel.frame = layout.metadataFrame
            if !durationBadge.isHidden, !layout.durationUsesSeparateLine {
                metaLabel.frame.size.width = max(1, durationBadge.frame.minX - 6 - metaLabel.frame.minX)
            }
        } else {
            metaLabel.frame = .zero
        }
        let menuHitSize = VideoCardOverflowButtonMetrics.hitSize
        let menuCenterInset = VideoCardOverflowButtonMetrics.cardEdgeInset + menuHitSize / 2
        menuButton.bounds = CGRect(x: 0, y: 0, width: menuHitSize, height: menuHitSize)
        menuButton.center = CGPoint(
            x: width - menuCenterInset,
            y: bounds.height - menuCenterInset
        )
    }

    func configure(
        model: MediaCardRenderModel,
        targetWidth: CGFloat,
        menu: UIMenu? = nil
    ) {
        menuButton.menu = menu
        menuButton.isHidden = menu == nil
        isUserInteractionEnabled = menu != nil
        guard self.model != model || configuredWidth != targetWidth else { return }
        self.model = model
        configuredWidth = targetWidth
        titleLabel.text = model.title
        authorLabel.text = model.author
        updateSurfaceAppearance()
        authorIcon.isHidden = !model.meta.showAuthor
        authorLabel.isHidden = !model.meta.showAuthor

        durationBadge.isHidden = !model.meta.showDuration || model.durationSec <= 0
        durationBadge.text = BiliFormat.duration(model.durationSec)
        metaLabel.attributedText = Self.metaText(model, font: metaLabel.font, traits: traitCollection, compact: targetWidth < 150)
        metaLabel.isHidden = !Self.showsMetadata(model)
        liveBadge.isHidden = model.liveInfo == nil
        coverImageView.isHidden = model.articleInfo != nil && model.cover.isEmpty
        publicationMetaLabel.attributedText = Self.metaText(model, font: publicationMetaLabel.font, traits: traitCollection,
                                                           compact: targetWidth < 150, publicationRow: true)
        publicationMetaLabel.isHidden = publicationMetaLabel.attributedText?.length == 0
        summaryLabel.text = model.articleInfo?.description
        summaryLabel.isHidden = model.articleInfo?.description.isEmpty != false
        secondaryMetaLabel.text = model.articleInfo.map { article in
            [article.categoryName, BiliFormat.relativeDate(model.pubdate)].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        secondaryMetaLabel.isHidden = model.articleInfo == nil

        accessibilityLabel = [model.title, model.author].filter { !$0.isEmpty }.joined(separator: "，")
        accessibilityTraits = .button
        loadImage(model.cover, targetWidth: targetWidth, quality: model.imageQuality)
        setNeedsLayout()
    }

    static func preferredHeight(width: CGFloat, meta: FeedCardMetaConfig) -> CGFloat {
        MediaCardLayout(width: width, showsAuthor: meta.showAuthor,
                        showsMetadata: meta.showPlay || (!meta.statOnPublicationRow && meta.stat != .none),
                        showsDuration: meta.showDuration, showsPubdate: meta.showPubdate,
                        showsStatWithPubdate: meta.statOnPublicationRow && meta.stat != .none,
                        compactMetadataLines: metadataLines(meta)).height
    }

    static func preferredHeight(width: CGFloat, model: MediaCardRenderModel) -> CGFloat {
        layout(width: width, model: model).height
    }

    private static func layout(width: CGFloat, model: MediaCardRenderModel) -> MediaCardLayout {
        MediaCardLayout(width: width, showsAuthor: model.meta.showAuthor,
                        showsMetadata: model.liveInfo != nil || showsMetadata(model), showsDuration: model.meta.showDuration,
                        showsOverflowMenu: model.liveInfo == nil && model.articleInfo == nil,
                        showsCover: model.articleInfo == nil || !model.cover.isEmpty,
                        showsSummary: model.articleInfo?.description.isEmpty == false,
                        showsSecondaryMetadata: model.articleInfo != nil,
                        showsPubdate: model.articleInfo == nil && model.meta.showPubdate,
                        showsStatWithPubdate: model.meta.statOnPublicationRow && model.meta.stat != .none,
                        compactMetadataLines: model.articleInfo != nil ? 3 : metadataLines(model.meta))
    }

    private static func metadataLines(_ meta: FeedCardMetaConfig) -> Int {
        meta.statOnPublicationRow ? 1 : max(2, (meta.showPlay ? 1 : 0) + (meta.stat != .none ? 1 : 0))
    }

    private static func showsMetadata(_ model: MediaCardRenderModel) -> Bool {
        if let live = model.liveInfo { return !live.watchedLabel.isEmpty || !live.areaName.isEmpty }
        if model.articleInfo != nil { return true }
        return model.meta.showPlay || (!model.meta.statOnPublicationRow && model.meta.stat != .none)
    }

    private static func metaText(_ model: MediaCardRenderModel, font: UIFont,
                                 traits: UITraitCollection, compact: Bool, publicationRow: Bool = false) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let color = UIColor.secondaryLabel.resolvedColor(with: traits)
        func append(_ value: String, symbol: String? = nil) {
            if text.length > 0 { text.append(NSAttributedString(string: compact ? "\n" : "  ·  ")) }
            if let symbol {
                let attachment = NSTextAttachment()
                attachment.image = UIImage(systemName: symbol)?.withTintColor(color, renderingMode: .alwaysOriginal)
                attachment.bounds = CGRect(x: 0, y: -1, width: 10, height: 10)
                text.append(NSAttributedString(attachment: attachment))
                text.append(NSAttributedString(string: " "))
            }
            text.append(NSAttributedString(string: value))
        }
        if publicationRow {
            if model.liveInfo == nil, model.articleInfo == nil, model.meta.showPubdate, model.pubdate > 0 {
                append(BiliFormat.relativeDate(model.pubdate))
            }
        } else if let live = model.liveInfo {
            if !live.watchedLabel.isEmpty { append(live.watchedLabel, symbol: "eye") }
            if !live.areaName.isEmpty { append(live.areaName) }
        } else if model.articleInfo != nil {
            append(BiliFormat.compactCount(model.play), symbol: "eye")
            append(BiliFormat.compactCount(model.danmaku), symbol: "bubble.left")
            append(BiliFormat.compactCount(model.like), symbol: "hand.thumbsup")
        } else {
            if model.meta.showPlay {
                append(BiliFormat.compactCount(model.play), symbol: "play.fill")
            }
        }
        if model.liveInfo == nil, model.articleInfo == nil, model.meta.statOnPublicationRow == publicationRow {
            switch model.meta.stat {
            case .none:
                break
            case .danmaku:
                append(BiliFormat.compactCount(model.danmaku), symbol: "text.bubble")
            case .like:
                append(BiliFormat.compactCount(model.like), symbol: "hand.thumbsup")
            }
        }
        text.addAttributes([.font: font, .foregroundColor: UIColor.secondaryLabel], range: NSRange(location: 0, length: text.length))
        return text
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateSurfaceAppearance()
            if let model, configuredWidth > 0 {
                loadImage(model.cover, targetWidth: configuredWidth, quality: model.imageQuality)
            }
        }
    }

    private func updateSurfaceAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dark = traitCollection.userInterfaceStyle == .dark
        layer.borderColor = (dark ? UIColor.white.withAlphaComponent(0.12) : UIColor.black.withAlphaComponent(0.08)).cgColor
        CATransaction.commit()
        let authorColor = model?.isAuthorFollowed == true ? IbiliTheme.accentUIColor : UIColor.secondaryLabel
        authorLabel.textColor = authorColor
        authorIcon.tintColor = authorColor
        if let model {
            metaLabel.attributedText = Self.metaText(model, font: metaLabel.font, traits: traitCollection,
                                                    compact: bounds.width < 150)
            publicationMetaLabel.attributedText = Self.metaText(model, font: publicationMetaLabel.font, traits: traitCollection,
                                                               compact: bounds.width < 150, publicationRow: true)
        }
    }

    private func loadImage(_ rawURL: String, targetWidth: CGFloat, quality: Int?) {
        guard let model else { return }
        let layout = Self.layout(width: targetWidth, model: model)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor.systemBackground.resolvedColor(with: traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let configuration = ExtendedCoverBackdrop.Configuration(panelAspectRatio: layout.infoHeight / targetWidth,
                                                                titleInsetRatio: (layout.titleFrame.minY + 4 - layout.coverHeight) / targetWidth,
                                                                red: red, green: green, blue: blue)
        let targetSize = CGSize(width: targetWidth, height: targetWidth / MediaCardLayout.coverAspectRatio)
        let resolved = BiliImageURL.resized(rawURL, pointSize: targetSize, quality: quality)
        guard let url = URL(string: resolved) else {
            imageTask?.cancel()
            representedRequest = nil
            representedBackdrop = nil
            coverImageView.image = nil
            backdropImageView.image = nil
            return
        }
        let maxPixelDimension = ImagePipeline.displayPixelDimension(for: targetSize)
        let request = ImageRequestKey(url: url, maxPixelDimension: maxPixelDimension)
        if representedRequest == request, representedBackdrop == configuration,
           imageTask != nil || backdropImageView.image != nil { return }
        imageTask?.cancel()
        representedRequest = request
        representedBackdrop = configuration
        backdropImageView.image = nil
        coverImageView.image = ImageCache.shared.image(for: url, maxPixelDimension: maxPixelDimension)
        imageTask = Task { [weak self] in
            let image = await ImagePipeline.shared.image(for: url, maxPixelDimension: maxPixelDimension)
            guard !Task.isCancelled,
                  let self,
                  self.representedRequest == request, self.representedBackdrop == configuration else { return }
            self.coverImageView.image = image
            if let bitmap = image?.cgImage {
                let backdrop = try? await BlockingWorkQueue.images.run(priority: .utility) {
                    ExtendedCoverBackdrop.image(for: bitmap, cacheKey: request.cacheKey as String, configuration: configuration)
                }
                guard !Task.isCancelled, self.representedRequest == request,
                      self.representedBackdrop == configuration else { return }
                self.backdropImageView.image = backdrop.map { UIImage(cgImage: $0) }
            }
            self.imageTask = nil
        }
    }
}

private final class MediaCardDurationLabel: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        textAlignment = .center
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let base = super.sizeThatFits(size)
        return CGSize(width: base.width + 12, height: 22)
    }

}
