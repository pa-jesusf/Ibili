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
    @Published private(set) var errorText: String?

    private(set) var bvid: String = ""

    /// Best-effort initial fill from the home/search list — lets us
    /// render title/cover before the network round-trip lands.
    func seed(from item: FeedItemDTO) {
        bvid = item.bvid
    }

    func bootstrap(bvid: String) async {
        guard self.view == nil || self.bvid != bvid else { return }
        self.bvid = bvid
        isLoading = true
        errorText = nil
        async let detail: VideoViewDTO = Task.detached(priority: .userInitiated) {
            try CoreClient.shared.videoViewFull(bvid: bvid)
        }.value
        async let relatedList: [RelatedVideoItemDTO] = Task.detached(priority: .utility) {
            (try? CoreClient.shared.videoRelated(bvid: bvid)) ?? []
        }.value

        do {
            let v = try await detail
            self.view = v
            self.related = await relatedList
            AppLog.info("video", "视频详情加载成功", metadata: [
                "bvid": bvid,
                "tags": String(v.tags.count),
                "pages": String(v.pages.count),
            ])
        } catch {
            self.errorText = (error as NSError).localizedDescription
            self.related = await relatedList
            AppLog.error("video", "视频详情加载失败", error: error, metadata: ["bvid": bvid])
        }
        isLoading = false
    }

    func refreshStat() async {
        guard !bvid.isEmpty else { return }
        if let updated = try? await Task.detached(priority: .utility) { [bvid = self.bvid] in
            try CoreClient.shared.videoViewFull(bvid: bvid)
        }.value {
            self.view = updated
        }
    }
}
