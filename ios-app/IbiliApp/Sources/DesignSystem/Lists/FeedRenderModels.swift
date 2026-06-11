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

struct FeedCardRenderModel: Hashable {
    let identity: FeedStableIdentity
    let item: FeedItemDTO
    let cardWidth: CGFloat
    let imageQuality: Int?
    let showsDurationAtTopTrailing: Bool
    let meta: FeedCardMetaConfig

    init(item: FeedItemDTO,
         cardWidth: CGFloat,
         imageQuality: Int?,
         showsDurationAtTopTrailing: Bool,
         meta: FeedCardMetaConfig) {
        self.identity = FeedStableIdentity(item)
        self.item = item
        self.cardWidth = cardWidth
        self.imageQuality = imageQuality
        self.showsDurationAtTopTrailing = showsDurationAtTopTrailing
        self.meta = meta
    }
}

struct VideoRowRenderModel: Hashable {
    let identity: FeedStableIdentity
    let title: String
    let cover: String
    let author: String
    let durationSec: Int64
    let play: Int64
    let danmaku: Int64
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
        durationPlacement: VideoCoverView.DurationPlacement = .bottomTrailing
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
}
