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
    /// True while `hydrate` is in flight. Lets the action row hold a
    /// loader instead of flashing wrong (default-false) icons before
    /// the server's relation state arrives.
    @Published private(set) var isHydrating: Bool = false
    /// True while a long-press 三连 operation is in flight. Drives the
    /// progress ring SwiftUI overlays around the like/coin/favorite
    /// trio so the user has clear feedback that the long-press was
    /// recognised even before the network round-trip lands.
    @Published private(set) var tripleAnimating: Bool = false
    /// Same idea, but specifically for the long-press “pick favourite
    /// folder” affordance — ring sweeps around the heart icon while
    /// the picker sheet animates in / the API call settles.
    @Published private(set) var favoriteAnimating: Bool = false
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
        isHydrating = true
        // Concurrently fetch relation state + folder list + watch-later
        // membership so all three buttons can render their *real* state
        // on first paint instead of defaulting to inactive.
        let snapshot = await Task.detached { () -> (ArchiveRelationDTO?, [FavFolderInfoDTO], Set<Int64>) in
            async let relTask: ArchiveRelationDTO? = {
                try? CoreClient.shared.archiveRelation(aid: aid, bvid: bvid)
            }()
            async let foldersTask: [FavFolderInfoDTO] = {
                let selfMid = CoreClient.shared.sessionSnapshot().mid
                guard selfMid > 0 else { return [] }
                return (try? CoreClient.shared.favFolders(rid: aid, upMid: selfMid)) ?? []
            }()
            async let watchLaterTask: Set<Int64> = {
                let aids = (try? CoreClient.shared.watchLaterAids()) ?? []
                return Set(aids)
            }()
            let (rel, folders, wl) = await (relTask, foldersTask, watchLaterTask)
            _ = ownerMid // unused; uploader follow state lives in `rel.attention`
            return (rel, folders, wl)
        }.value

        if let rel = snapshot.0 {
            state.liked = rel.liked
            state.coined = rel.coinNumber > 0
            state.favorited = rel.favorited
            state.followed = rel.attention
        }
        // Watch-later membership: server returns the full toview list
        // (capped ~100 most-recent), so contains() is the right check.
        // Anonymous sessions yield an empty set → inWatchLater=false.
        state.inWatchLater = snapshot.2.contains(aid)
        folders = snapshot.1
        favoritedFolderIds = Set(snapshot.1.filter { $0.favState == 1 }.map { $0.folderId })
        // Bilibili marks the default folder via `attr & 1 == 1`. Fall
        // back to the first folder so we always have a target.
        if let def = snapshot.1.first(where: { $0.attr & 1 == 1 }) {
            defaultFolderId = def.folderId
        } else if let first = snapshot.1.first {
            defaultFolderId = first.folderId
        }
        isHydrating = false
    }

    // MARK: - Like

    func toggleLike(aid: Int64) {
        let old = state
        let willLike = !state.liked
        state.liked = willLike
        state.likeCount = max(0, state.likeCount + (willLike ? 1 : -1))
        let action: Int32 = willLike ? 1 : 2
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.archiveLike(aid: aid, action: action)
                }.value
            } catch {
                state = old
                lastToast = "操作失败"
                AppLog.error("interaction", "点赞失败", error: error, metadata: ["aid": String(aid)])
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
        Task {
            do {
                let toast = try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.archiveCoin(aid: aid, multiply: multiply, alsoLike: alsoLike).toast
                }.value
                if !toast.isEmpty { lastToast = toast }
            } catch {
                state = old
                lastToast = "投币失败"
                AppLog.error("interaction", "投币失败", error: error, metadata: ["aid": String(aid)])
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
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.archiveFavorite(aid: aid, addIds: addIds, delIds: delIds)
                }.value
            } catch {
                state = old
                favoritedFolderIds = oldFolderIds
                lastToast = "收藏失败"
                AppLog.error("interaction", "收藏失败", error: error, metadata: ["aid": String(aid)])
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
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.archiveFavorite(aid: aid, addIds: addIds, delIds: delIds)
                }.value
                lastToast = "收藏已更新"
            } catch {
                state = old
                favoritedFolderIds = oldFolderIds
                lastToast = "收藏失败"
                AppLog.error("interaction", "收藏失败", error: error, metadata: ["aid": String(aid)])
            }
        }
    }

    // MARK: - Triple

    func triple(aid: Int64) {
        // Idempotency guard: if all three are already done, just nudge
        // the user instead of hitting the server (which would otherwise
        // try to add another coin on top of the existing 1, racing the
        // 2-coin cap and flashing a confusing toast).
        if state.liked && state.coined && state.favorited {
            lastToast = "已三连过"
            return
        }
        let old = state
        state.liked = true
        state.coined = true
        state.favorited = true
        tripleAnimating = true
        Task {
            // Floor the in-flight window at ~0.7s so the ring sweep
            // is always visible — instant successes otherwise flash
            // off before the eye registers the animation.
            async let minDelay: () = Task.sleep(nanoseconds: 700_000_000)
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let response = try CoreClient.shared.archiveTriple(aid: aid)
                    return (response.like, response.coin, response.fav, response.prompt)
                }.value
                try? await minDelay
                state.liked = result.0 || state.liked
                state.coined = result.1 || state.coined
                state.favorited = result.2 || state.favorited
                if result.3 { lastToast = "三连成功" }
                tripleAnimating = false
            } catch {
                try? await minDelay
                state = old
                lastToast = "三连失败"
                tripleAnimating = false
                AppLog.error("interaction", "三连失败", error: error, metadata: ["aid": String(aid)])
            }
        }
    }

    /// Begin / end the long-press favourite ring animation. Called by
    /// `VideoActionRow` around presenting the folder picker so the
    /// user gets the same visual confirmation the triple ring gives.
    func setFavoriteAnimating(_ animating: Bool) {
        favoriteAnimating = animating
    }

    // MARK: - Follow

    func toggleFollow(fid: Int64) {
        let old = state
        let willFollow = !state.followed
        state.followed = willFollow
        let act: Int32 = willFollow ? 1 : 2
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.relationModify(fid: fid, act: act)
                }.value
            } catch {
                state = old
                lastToast = "关注操作失败"
                AppLog.error("interaction", "关注失败", error: error, metadata: ["fid": String(fid)])
            }
        }
    }

    // MARK: - Watch later

    func toggleWatchLater(aid: Int64) {
        let old = state
        let willAdd = !state.inWatchLater
        state.inWatchLater = willAdd
        Task {
            do {
                if willAdd {
                    try await Task.detached(priority: .userInitiated) {
                        try CoreClient.shared.watchLaterAdd(aid: aid)
                    }.value
                    lastToast = "已添加稍后再看"
                } else {
                    try await Task.detached(priority: .userInitiated) {
                        try CoreClient.shared.watchLaterDel(aid: aid)
                    }.value
                    lastToast = "已移除"
                }
            } catch {
                state = old
                lastToast = "稍后再看操作失败"
                AppLog.error("interaction", "稍后再看失败", error: error, metadata: ["aid": String(aid)])
            }
        }
    }
}
