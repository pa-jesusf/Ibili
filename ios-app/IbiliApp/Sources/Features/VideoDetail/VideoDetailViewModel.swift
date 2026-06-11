import Foundation

/// Owns the network state for the video detail page: full view info,
/// related list, and (separately) the comment list. Comments are
/// owned by their own VM (`CommentListViewModel`) so the detail VM
/// can stay tab-agnostic and not pay decode cost when the user never
/// opens that tab.
@MainActor
final class VideoDetailViewModel: ObservableObject {
    @Published private(set) var view: VideoViewDTO?
    @Published private(set) var related: [RelatedVideoItemDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMoreRelated = false
    @Published private(set) var relatedIsEnd = false
    @Published private(set) var errorText: String?

    private(set) var aid: Int64 = 0
    private(set) var bvid: String = ""
    private var feedFreshIdx: Int64 = 1
    private var seenAids: Set<Int64> = []

    /// Best-effort initial fill from the home/search list — lets us
    /// render title/cover before the network round-trip lands.
    func seed(from item: FeedItemDTO) {
        aid = item.aid
        bvid = item.bvid
    }

    func bootstrap(aid: Int64, bvid: String) async {
        await loadDetail(aid: aid, bvid: bvid, force: false)
    }

    func refresh(aid: Int64, bvid: String) async {
        await loadDetail(aid: aid, bvid: bvid, force: true)
    }

    func refreshStat() async {
        guard aid > 0 || !bvid.isEmpty else { return }
        if let updated = try? await Task.detached(priority: .utility, operation: { [aid = self.aid, bvid = self.bvid] in
            try CoreClient.shared.videoViewFull(aid: aid, bvid: bvid)
        }).value {
            self.aid = updated.aid
            self.bvid = updated.bvid.isEmpty ? bvid : updated.bvid
            self.view = updated
        }
    }

    func matchesLoadedDetail(aid: Int64, bvid: String) -> Bool {
        guard view != nil, self.aid == aid else { return false }
        return self.bvid.isEmpty || bvid.isEmpty || self.bvid == bvid
    }

    /// `archive/related` is one-shot (~30 items, no native pagination).
    /// Once the user reaches the end of that list we fall back to the
    /// home feed (`feed.home`) and keep appending fresh items so the
    /// related rail behaves like an infinite list.
    func loadMoreRelated() async {
        guard !isLoadingMoreRelated, !relatedIsEnd else { return }
        isLoadingMoreRelated = true
        defer { isLoadingMoreRelated = false }
        var fresh: [RelatedVideoItemDTO] = []
        var reachedEnd = false
        var nextIdx = feedFreshIdx

        // Home feed pages can contain duplicates of the current detail or
        // previously appended rows. Keep walking a few pages so pagination
        // never appears to stall just because one page was all duplicates.
        for _ in 0..<3 where fresh.isEmpty {
            let idx = nextIdx
            let page = await Task.detached(priority: .utility) {
                (try? CoreClient.shared.feedHome(idx: idx, ps: 12, source: "web"))
            }.value
            guard let page else {
                reachedEnd = true
                break
            }
            nextIdx += 1
            if page.items.isEmpty {
                reachedEnd = true
                break
            }
            fresh.append(contentsOf: page.items.compactMap(feedItemToFreshRelated(_:)))
        }

        feedFreshIdx = nextIdx
        if fresh.isEmpty {
            relatedIsEnd = reachedEnd
            return
        }
        related.append(contentsOf: fresh)
    }

    private func loadDetail(aid: Int64, bvid: String, force: Bool) async {
        guard force || self.view == nil || self.aid != aid || self.bvid != bvid else { return }
        let hadVisibleContent = view != nil || !related.isEmpty
        self.aid = aid
        self.bvid = bvid
        isLoading = true
        errorText = nil
        do {
            let v = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.videoViewFull(aid: aid, bvid: bvid)
            }.value
            let resolvedBvid = v.bvid.isEmpty ? bvid : v.bvid
            self.aid = v.aid
            self.bvid = resolvedBvid
            self.view = v
            let fetchedRelated = await Task.detached(priority: .utility) {
                (try? CoreClient.shared.videoRelated(aid: v.aid, bvid: resolvedBvid)) ?? []
            }.value
            self.related = self.uniqueRelatedItems(fetchedRelated, currentAid: v.aid)
            self.seenAids = Set(self.related.map { $0.aid })
            self.seenAids.insert(v.aid)
            self.relatedIsEnd = false
            self.feedFreshIdx = 1
            AppLog.info("video", force ? "视频详情刷新成功" : "视频详情加载成功", metadata: [
                "aid": String(v.aid),
                "bvid": resolvedBvid,
                "tags": String(v.tags.count),
                "pages": String(v.pages.count),
            ])
        } catch {
            self.errorText = (error as NSError).localizedDescription
            if !hadVisibleContent {
                self.related = []
            }
            AppLog.error("video", force ? "视频详情刷新失败" : "视频详情加载失败", error: error, metadata: [
                "aid": String(aid),
                "bvid": bvid,
            ])
        }
        isLoading = false
    }

    private func uniqueRelatedItems(_ incoming: [RelatedVideoItemDTO], currentAid: Int64) -> [RelatedVideoItemDTO] {
        var seen = Set<Int64>()
        seen.insert(currentAid)
        var result: [RelatedVideoItemDTO] = []
        result.reserveCapacity(incoming.count)
        for item in incoming {
            guard item.aid > 0 else { continue }
            guard seen.insert(item.aid).inserted else { continue }
            result.append(item)
        }
        return result
    }

    private func feedItemToFreshRelated(_ item: FeedItemDTO) -> RelatedVideoItemDTO? {
        guard item.aid > 0, item.aid != aid else { return nil }
        guard seenAids.insert(item.aid).inserted else { return nil }
        return RelatedVideoItemDTO(
            aid: item.aid,
            bvid: item.bvid,
            cid: item.cid,
            title: item.title,
            cover: item.cover,
            author: item.author,
            face: "",
            mid: item.ownerMID,
            durationSec: item.durationSec,
            play: item.play,
            danmaku: item.danmaku,
            pubdate: 0
        )
    }
}
