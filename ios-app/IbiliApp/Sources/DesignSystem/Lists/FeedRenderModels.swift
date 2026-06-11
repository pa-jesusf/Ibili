import CoreGraphics
import Foundation

struct FeedStableIdentity: Hashable, Sendable {
    let aid: Int64
    let bvid: String
    let cid: Int64
    let epID: Int64
    let roomID: Int64

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
