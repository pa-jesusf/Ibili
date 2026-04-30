import Foundation

/// Optimistic-UI wrapper around the write-action endpoints exposed by
/// the Rust core (like / coin / favorite / triple / follow / watch
/// later). Each method updates the `state` synchronously on the calling
/// thread, fires the network call on a background task, and rolls back
/// on failure. A small `lastToast` channel surfaces server-side messages
/// (e.g. "投币成功") to the caller for HUD display.
@MainActor
final class VideoInteractionService: ObservableObject {
    struct State: Equatable {
        var liked: Bool = false
        var coined: Bool = false
        var favorited: Bool = false
        var followed: Bool = false
        var inWatchLater: Bool = false
        var likeCount: Int64 = 0
        var coinCount: Int64 = 0
        var favoriteCount: Int64 = 0
    }

    @Published private(set) var state = State()
    @Published private(set) var folders: [FavFolderInfoDTO] = []
    @Published private(set) var defaultFolderId: Int64 = 0
    /// `id`s of the folders the current video is already in. Used to
    /// preselect rows in the long-press folder picker.
    @Published private(set) var favoritedFolderIds: Set<Int64> = []
    @Published var lastToast: String?

    init() {}

    func reset(stat: VideoStatDTO) {
        state.likeCount = stat.like
        state.coinCount = stat.coin
        state.favoriteCount = stat.favorite
    }

    /// Pull the server-side relation state plus the user's favourite
    /// folder list so the action row can render the correct active
    /// states and the long-press folder picker has data immediately.
    func hydrate(aid: Int64, bvid: String, ownerMid: Int64?) async {
        // Relation (like/coin/fav/follow) state.
        let snapshot = await Task.detached { () -> (ArchiveRelationDTO?, [FavFolderInfoDTO]) in
            let rel = try? CoreClient.shared.archiveRelation(aid: aid, bvid: bvid)
            // Folder list is keyed off the *self* mid, not the uploader.
            let selfMid = CoreClient.shared.sessionSnapshot().mid
            var folders: [FavFolderInfoDTO] = []
            if selfMid > 0 {
                folders = (try? CoreClient.shared.favFolders(rid: aid, upMid: selfMid)) ?? []
            }
            _ = ownerMid // currently unused; uploader follow state comes from `rel.attention`
            return (rel, folders)
        }.value

        if let rel = snapshot.0 {
            state.liked = rel.liked
            state.coined = rel.coinNumber > 0
            state.favorited = rel.favorited
            state.followed = rel.attention
        }
        folders = snapshot.1
        favoritedFolderIds = Set(snapshot.1.filter { $0.favState == 1 }.map { $0.folderId })
        // Bilibili marks the default folder via `attr & 1 == 1`. Fall
        // back to the first folder so we always have a target.
        if let def = snapshot.1.first(where: { $0.attr & 1 == 1 }) {
            defaultFolderId = def.folderId
        } else if let first = snapshot.1.first {
            defaultFolderId = first.folderId
        }
    }

    // MARK: - Like

    func toggleLike(aid: Int64) {
        let old = state
        let willLike = !state.liked
        state.liked = willLike
        state.likeCount = max(0, state.likeCount + (willLike ? 1 : -1))
        let action: Int32 = willLike ? 1 : 2
        Task.detached { [weak self] in
            do {
                _ = try CoreClient.shared.archiveLike(aid: aid, action: action)
            } catch {
                await MainActor.run {
                    self?.state = old
                    self?.lastToast = "操作失败"
                    AppLog.error("interaction", "点赞失败", error: error, metadata: ["aid": String(aid)])
                }
            }
        }
    }

    // MARK: - Coin

    func addCoin(aid: Int64, multiply: Int32, alsoLike: Bool) {
        let old = state
        state.coined = true
        state.coinCount += Int64(multiply)
        if alsoLike, !state.liked {
            state.liked = true
            state.likeCount += 1
        }
        Task.detached { [weak self] in
            do {
                let r = try CoreClient.shared.archiveCoin(aid: aid, multiply: multiply, alsoLike: alsoLike)
                await MainActor.run { if !r.toast.isEmpty { self?.lastToast = r.toast } }
            } catch {
                await MainActor.run {
                    self?.state = old
                    self?.lastToast = "投币失败"
                    AppLog.error("interaction", "投币失败", error: error, metadata: ["aid": String(aid)])
                }
            }
        }
    }

    // MARK: - Favorite (default folder via add_ids fetched from server)

    /// Toggle a video into / out of the default favourite folder.
    /// Caller passes the folder id. (UI may show a folder picker; for
    /// the simple toggle we just use one folder.)
    func toggleFavorite(aid: Int64, defaultFolderId: Int64) {
        let old = state
        let oldFolderIds = favoritedFolderIds
        let willFav = !state.favorited
        state.favorited = willFav
        state.favoriteCount = max(0, state.favoriteCount + (willFav ? 1 : -1))
        let addIds: [Int64] = willFav ? [defaultFolderId] : []
        let delIds: [Int64] = willFav ? [] : Array(oldFolderIds)
        if willFav { favoritedFolderIds = [defaultFolderId] } else { favoritedFolderIds.removeAll() }
        Task.detached { [weak self] in
            do {
                _ = try CoreClient.shared.archiveFavorite(aid: aid, addIds: addIds, delIds: delIds)
            } catch {
                await MainActor.run {
                    self?.state = old
                    self?.favoritedFolderIds = oldFolderIds
                    self?.lastToast = "收藏失败"
                    AppLog.error("interaction", "收藏失败", error: error, metadata: ["aid": String(aid)])
                }
            }
        }
    }

    /// Apply a folder selection from the long-press picker. `selected`
    /// is the new full set of folder ids the video should belong to.
    func applyFavoriteSelection(aid: Int64, selected: Set<Int64>) {
        let old = state
        let oldFolderIds = favoritedFolderIds
        let addIds = Array(selected.subtracting(oldFolderIds))
        let delIds = Array(oldFolderIds.subtracting(selected))
        if addIds.isEmpty, delIds.isEmpty { return }
        favoritedFolderIds = selected
        state.favorited = !selected.isEmpty
        // Don't try to back-compute count — will be re-hydrated from
        // server toast or the next detail view refresh.
        Task.detached { [weak self] in
            do {
                _ = try CoreClient.shared.archiveFavorite(aid: aid, addIds: addIds, delIds: delIds)
                await MainActor.run { self?.lastToast = "收藏已更新" }
            } catch {
                await MainActor.run {
                    self?.state = old
                    self?.favoritedFolderIds = oldFolderIds
                    self?.lastToast = "收藏失败"
                    AppLog.error("interaction", "收藏失败", error: error, metadata: ["aid": String(aid)])
                }
            }
        }
    }

    // MARK: - Triple

    func triple(aid: Int64) {
        let old = state
        state.liked = true
        state.coined = true
        state.favorited = true
        Task.detached { [weak self] in
            do {
                let r = try CoreClient.shared.archiveTriple(aid: aid)
                await MainActor.run {
                    self?.state.liked = r.like || (self?.state.liked ?? false)
                    self?.state.coined = r.coin || (self?.state.coined ?? false)
                    self?.state.favorited = r.fav || (self?.state.favorited ?? false)
                    if r.prompt { self?.lastToast = "三连成功" }
                }
            } catch {
                await MainActor.run {
                    self?.state = old
                    self?.lastToast = "三连失败"
                    AppLog.error("interaction", "三连失败", error: error, metadata: ["aid": String(aid)])
                }
            }
        }
    }

    // MARK: - Follow

    func toggleFollow(fid: Int64) {
        let old = state
        let willFollow = !state.followed
        state.followed = willFollow
        let act: Int32 = willFollow ? 1 : 2
        Task.detached { [weak self] in
            do {
                try CoreClient.shared.relationModify(fid: fid, act: act)
            } catch {
                await MainActor.run {
                    self?.state = old
                    self?.lastToast = "关注操作失败"
                    AppLog.error("interaction", "关注失败", error: error, metadata: ["fid": String(fid)])
                }
            }
        }
    }

    // MARK: - Watch later

    func toggleWatchLater(aid: Int64) {
        let old = state
        let willAdd = !state.inWatchLater
        state.inWatchLater = willAdd
        Task.detached { [weak self] in
            do {
                if willAdd {
                    try CoreClient.shared.watchLaterAdd(aid: aid)
                    await MainActor.run { self?.lastToast = "已添加稍后再看" }
                } else {
                    try CoreClient.shared.watchLaterDel(aid: aid)
                    await MainActor.run { self?.lastToast = "已移除" }
                }
            } catch {
                await MainActor.run {
                    self?.state = old
                    self?.lastToast = "稍后再看操作失败"
                    AppLog.error("interaction", "稍后再看失败", error: error, metadata: ["aid": String(aid)])
                }
            }
        }
    }
}
