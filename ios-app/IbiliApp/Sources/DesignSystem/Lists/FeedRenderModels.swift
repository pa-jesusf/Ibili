import CoreGraphics
import Foundation

struct FeedStableIdentity: Hashable, Sendable {
    let aid: Int64
    let bvid: String
    let cid: Int64
    let epID: Int64
    let roomID: Int64

    init(aid: Int64 = 0, bvid: String = "", cid: Int64 = 0, epID: Int64 = 0, roomID: Int64 = 0) {
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        self.epID = epID
        self.roomID = roomID
    }

    init(_ item: FeedItemDTO) {
        aid = item.aid
        bvid = item.bvid
        cid = item.cid
        epID = item.epID
        roomID = 0
    }

    init(_ item: LiveFeedItemDTO) {
        aid = 0
        bvid = ""
        cid = 0
        epID = 0
        roomID = item.roomID
    }

    init(_ item: RelatedVideoItemDTO) {
        aid = item.aid
        bvid = item.bvid
        cid = item.cid
        epID = 0
        roomID = 0
    }

    init(_ item: SearchVideoItemDTO) {
        aid = item.aid
        bvid = item.bvid
        cid = item.cid
        epID = 0
        roomID = 0
    }

    var isValid: Bool {
        aid > 0 || epID > 0 || cid > 0 || roomID > 0 || !bvid.isEmpty
    }
}

struct LiveCardInfo: Hashable {
    let watchedLabel: String
    let areaName: String
}

struct MediaCardAppearance: Hashable {
    let imageQuality: Int?
    let meta: FeedCardMetaConfig
}

struct ArticleCardInfo: Hashable {
    let description: String
    let categoryName: String
}

struct MediaCardRenderModel: Hashable, Identifiable {
    var id: FeedStableIdentity { identity }
    let identity: FeedStableIdentity
    let title: String
    let cover: String
    let author: String
    let ownerMID: Int64
    let durationSec: Int64
    let play: Int64
    let danmaku: Int64
    let like: Int64
    let pubdate: Int64
    let isAuthorFollowed: Bool
    let imageQuality: Int?
    let meta: FeedCardMetaConfig
    let durationPlacement: VideoCoverView.DurationPlacement
    let liveInfo: LiveCardInfo?
    let articleInfo: ArticleCardInfo?

    init(
        identity: FeedStableIdentity,
        title: String,
        cover: String,
        author: String,
        ownerMID: Int64 = 0,
        durationSec: Int64,
        play: Int64,
        danmaku: Int64,
        like: Int64 = 0,
        pubdate: Int64 = 0,
        isAuthorFollowed: Bool = false,
        imageQuality: Int?,
        meta: FeedCardMetaConfig,
        durationPlacement: VideoCoverView.DurationPlacement = .bottomTrailing,
        liveInfo: LiveCardInfo? = nil,
        articleInfo: ArticleCardInfo? = nil
    ) {
        self.identity = identity
        self.title = title
        self.cover = cover
        self.author = author
        self.ownerMID = ownerMID
        self.durationSec = durationSec
        self.play = play
        self.danmaku = danmaku
        self.like = like
        self.pubdate = pubdate
        self.isAuthorFollowed = isAuthorFollowed
        self.imageQuality = imageQuality
        self.meta = meta
        self.durationPlacement = durationPlacement
        self.liveInfo = liveInfo
        self.articleInfo = articleInfo
    }

    init(live item: LiveFeedItemDTO, imageQuality: Int?) {
        self.init(identity: FeedStableIdentity(item), title: item.title,
                  cover: item.systemCover.isEmpty ? item.cover : item.systemCover,
                  author: item.uname, durationSec: 0, play: 0, danmaku: 0,
                  isAuthorFollowed: item.isFollowed, imageQuality: imageQuality,
                  meta: .init(showPlay: false, showDuration: false, showPubdate: false, showAuthor: true, stat: .none),
                  liveInfo: .init(watchedLabel: item.watchedLabel, areaName: item.areaName))
    }

    init(searchLive item: SearchLiveItemDTO, imageQuality: Int?) {
        self.init(identity: FeedStableIdentity(roomID: item.roomID), title: item.title,
                  cover: item.cover, author: item.uname, durationSec: 0, play: 0, danmaku: 0,
                  imageQuality: imageQuality,
                  meta: .init(showPlay: false, showDuration: false, showPubdate: false, showAuthor: true, stat: .none),
                  liveInfo: .init(watchedLabel: item.online > 0 ? BiliFormat.compactCount(item.online) : "",
                                  areaName: item.areaName))
    }

    init(searchArticle item: SearchArticleItemDTO, imageQuality: Int?) {
        self.init(identity: .init(), title: item.title, cover: item.cover, author: "",
                  durationSec: 0, play: item.view, danmaku: item.reply, like: item.like, pubdate: item.pubTime,
                  imageQuality: imageQuality,
                  meta: .init(showPlay: false, showDuration: false, showPubdate: false, showAuthor: false, stat: .none),
                  articleInfo: .init(description: item.desc, categoryName: item.categoryName))
    }

    init(
        feed item: FeedItemDTO,
        imageQuality: Int?,
        meta: FeedCardMetaConfig,
        durationPlacement: VideoCoverView.DurationPlacement = .bottomTrailing
    ) {
        self.init(
            identity: FeedStableIdentity(item),
            title: item.title,
            cover: item.cover,
            author: item.author,
            ownerMID: item.ownerMID,
            durationSec: item.durationSec,
            play: item.play,
            danmaku: item.danmaku,
            pubdate: item.pubdate,
            isAuthorFollowed: item.isFollowed,
            imageQuality: imageQuality,
            meta: meta,
            durationPlacement: durationPlacement
        )
    }

    init(
        search item: SearchVideoItemDTO,
        imageQuality: Int?,
        meta: FeedCardMetaConfig
    ) {
        self.init(
            identity: FeedStableIdentity(item),
            title: item.title,
            cover: item.cover,
            author: item.author,
            ownerMID: item.ownerMID,
            durationSec: item.durationSec,
            play: item.play,
            danmaku: item.danmaku,
            like: item.like,
            pubdate: item.pubdate,
            imageQuality: imageQuality,
            meta: meta
        )
    }

    init(
        related item: RelatedVideoItemDTO,
        imageQuality: Int? = 75,
        meta: FeedCardMetaConfig = .standard
    ) {
        self.init(
            identity: FeedStableIdentity(item),
            title: item.title,
            cover: item.cover,
            author: item.author,
            ownerMID: item.mid,
            durationSec: item.durationSec,
            play: item.play,
            danmaku: item.danmaku,
            pubdate: item.pubdate,
            imageQuality: imageQuality,
            meta: meta
        )
    }

    init(
        history item: HistoryItemDTO,
        imageQuality: Int? = 75,
        meta: FeedCardMetaConfig = .standard
    ) {
        self.init(
            identity: FeedStableIdentity(aid: item.aid, bvid: item.bvid, cid: item.cid),
            title: item.title,
            cover: item.cover,
            author: item.author,
            durationSec: item.durationSec,
            play: 0,
            danmaku: 0,
            imageQuality: imageQuality,
            meta: meta
        )
    }

    init(
        watchLater item: WatchLaterItemDTO,
        imageQuality: Int? = 75,
        meta: FeedCardMetaConfig = .standard
    ) {
        self.init(
            identity: FeedStableIdentity(aid: item.aid, bvid: item.bvid, cid: item.cid),
            title: item.title,
            cover: item.cover,
            author: item.author,
            durationSec: item.durationSec,
            play: 0,
            danmaku: 0,
            imageQuality: imageQuality,
            meta: meta
        )
    }

    init(
        favorite item: FavResourceItemDTO,
        imageQuality: Int? = 75,
        meta: FeedCardMetaConfig = .standard
    ) {
        self.init(
            identity: FeedStableIdentity(aid: item.aid, bvid: item.bvid, cid: item.cid),
            title: item.title,
            cover: item.cover,
            author: item.author,
            durationSec: item.durationSec,
            play: item.play,
            danmaku: item.danmaku,
            pubdate: item.pubdate,
            imageQuality: imageQuality,
            meta: meta
        )
    }

    init(
        subscription item: SubscriptionResourceDTO,
        author: String,
        imageQuality: Int? = 75,
        meta: FeedCardMetaConfig = .standard
    ) {
        self.init(
            identity: FeedStableIdentity(aid: item.aid, bvid: item.bvid, cid: item.cid),
            title: item.title,
            cover: item.cover,
            author: author,
            durationSec: item.durationSec,
            play: item.play,
            danmaku: item.danmaku,
            pubdate: item.pubdate,
            imageQuality: imageQuality,
            meta: meta
        )
    }
}
