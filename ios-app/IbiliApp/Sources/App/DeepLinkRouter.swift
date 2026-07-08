import SwiftUI
import Combine

/// Shared deep-link state. The video-detail tab handles `ibili://bv/<id>`
/// and `ibili://av/<id>` URLs emitted by `RichReplyText` jump-links.
///
/// The user comes in via SwiftUI's `OpenURLAction`; we parse it into a content
/// route and open a session host above the current tab. The host owns one
/// `NavigationStack`, so even the first content page is pushed through the same
/// stack as subsequent video/user/search/article jumps.
@MainActor
final class DeepLinkRouter: ObservableObject {
    private static let maxPushedPlayerRoutes = 3
    private static let maxPushedLiveRoutes = 2
    private static let maxSessionPathDepth = 12

    struct PlayerRoute: Hashable, Identifiable {
        let id: UUID
        var item: FeedItemDTO
        var offlineOnly: Bool

        init(id: UUID = UUID(), item: FeedItemDTO, offlineOnly: Bool = false) {
            self.id = id
            self.item = item
            self.offlineOnly = offlineOnly
        }

        func replacingItem(_ item: FeedItemDTO) -> Self {
            Self(id: id, item: item, offlineOnly: offlineOnly)
        }

        func replacingOfflineOnly(_ offlineOnly: Bool) -> Self {
            Self(id: id, item: item, offlineOnly: offlineOnly)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(item.aid)
            hasher.combine(item.bvid)
            hasher.combine(item.cid)
            hasher.combine(item.epID)
            hasher.combine(item.seasonID)
            hasher.combine(item.isPGC)
            hasher.combine(offlineOnly)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
                && lhs.item.aid == rhs.item.aid
                && lhs.item.bvid == rhs.item.bvid
                && lhs.item.cid == rhs.item.cid
                && lhs.item.epID == rhs.item.epID
                && lhs.item.seasonID == rhs.item.seasonID
                && lhs.item.isPGC == rhs.item.isPGC
                && lhs.offlineOnly == rhs.offlineOnly
        }
    }

    struct LiveRoute: Hashable, Identifiable {
        let id: UUID
        let roomID: Int64
        let title: String
        let cover: String
        let anchorName: String

        init(
            id: UUID = UUID(),
            roomID: Int64,
            title: String = "",
            cover: String = "",
            anchorName: String = ""
        ) {
            self.id = id
            self.roomID = roomID
            self.title = title
            self.cover = cover
            self.anchorName = anchorName
        }

        func replacingMetadata(title: String, cover: String, anchorName: String) -> Self {
            Self(
                id: id,
                roomID: roomID,
                title: title,
                cover: cover,
                anchorName: anchorName
            )
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(roomID)
            hasher.combine(title)
            hasher.combine(cover)
            hasher.combine(anchorName)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
                && lhs.roomID == rhs.roomID
                && lhs.title == rhs.title
                && lhs.cover == rhs.cover
                && lhs.anchorName == rhs.anchorName
        }
    }

    struct UserSpaceRoute: Hashable, Identifiable {
        let id: UUID
        let mid: Int64

        init(id: UUID = UUID(), mid: Int64) {
            self.id = id
            self.mid = mid
        }
    }

    struct DynamicDetailRoute: Hashable, Identifiable {
        let id: UUID
        let item: DynamicItemDTO

        init(id: UUID = UUID(), item: DynamicItemDTO) {
            self.id = id
            self.item = item
        }
    }

    struct ArticleRoute: Hashable, Identifiable {
        let id: UUID
        let articleID: String
        let kind: String

        init(id: UUID = UUID(), articleID: String, kind: String) {
            self.id = id
            self.articleID = articleID
            self.kind = kind
        }
    }

    struct SearchRoute: Hashable, Identifiable {
        let id: UUID
        let keyword: String

        init(id: UUID = UUID(), keyword: String) {
            self.id = id
            self.keyword = keyword
        }
    }

    enum SessionRoute: Hashable, Identifiable {
        case player(PlayerRoute)
        case live(LiveRoute)
        case userSpace(UserSpaceRoute)
        case dynamicDetail(DynamicDetailRoute)
        case article(ArticleRoute)
        case search(SearchRoute)

        var id: UUID {
            switch self {
            case .player(let route):
                return route.id
            case .live(let route):
                return route.id
            case .userSpace(let route):
                return route.id
            case .dynamicDetail(let route):
                return route.id
            case .article(let route):
                return route.id
            case .search(let route):
                return route.id
            }
        }

        var playerRoute: PlayerRoute? {
            guard case .player(let route) = self else { return nil }
            return route
        }

        var liveRoute: LiveRoute? {
            guard case .live(let route) = self else { return nil }
            return route
        }

        var rootRoute: RootRoute {
            switch self {
            case .player(let route):
                return .player(route)
            case .live(let route):
                return .live(route)
            case .userSpace(let route):
                return .userSpace(route)
            case .dynamicDetail(let route):
                return .dynamicDetail(route)
            case .article(let route):
                return .article(route)
            case .search(let route):
                return .search(route)
            }
        }

    }

    enum RootRoute: Hashable, Identifiable {
        case player(PlayerRoute)
        case live(LiveRoute)
        case dynamicDetail(DynamicDetailRoute)
        case userSpace(UserSpaceRoute)
        case article(ArticleRoute)
        case search(SearchRoute)

        var id: UUID {
            switch self {
            case .player(let route):
                return route.id
            case .live(let route):
                return route.id
            case .dynamicDetail(let route):
                return route.id
            case .userSpace(let route):
                return route.id
            case .article(let route):
                return route.id
            case .search(let route):
                return route.id
            }
        }

        var playerRoute: PlayerRoute? {
            guard case .player(let route) = self else { return nil }
            return route
        }

        var liveRoute: LiveRoute? {
            guard case .live(let route) = self else { return nil }
            return route
        }
    }

    struct SessionSnapshot {
        var pending: RootRoute?
        var path: [SessionRoute]
    }

    @Published var pending: RootRoute?
    /// Navigation path inside the active content session. `pending` is the
    /// stable session anchor, while every displayed page, including the first
    /// one, lives in this path so SwiftUI can drive native push/pop and toolbar
    /// transitions uniformly.
    @Published var path: [SessionRoute] = []
    @Published private(set) var isClosingRootSession = false

    enum OpenMode {
        case push
        case replaceCurrent
    }

    var currentRoute: PlayerRoute? {
        path.reversed().compactMap(\.playerRoute).first ?? pending?.playerRoute
    }

    var currentItem: FeedItemDTO? {
        currentRoute?.item
    }

    var playerPath: [PlayerRoute] {
        path.compactMap(\.playerRoute)
    }

    var livePath: [LiveRoute] {
        path.compactMap(\.liveRoute)
    }

    var foregroundPlayerRouteID: PlayerSessionID? {
        if case .player(let route)? = path.last {
            return route.id
        }
        return nil
    }

    var foregroundLiveRouteID: PlayerSessionID? {
        if case .live(let route)? = path.last {
            return route.id
        }
        return nil
    }

    var snapshot: SessionSnapshot {
        SessionSnapshot(pending: pending, path: path)
    }

    func open(_ item: FeedItemDTO, mode: OpenMode = .push) {
        openPlayer(item, offlineOnly: false, mode: mode)
    }

    func openOffline(_ item: FeedItemDTO, mode: OpenMode = .push) {
        openPlayer(item, offlineOnly: true, mode: mode)
    }

    func select(_ item: FeedItemDTO) {
        selectPlayer(item, offlineOnly: false)
    }

    func selectOffline(_ item: FeedItemDTO) {
        selectPlayer(item, offlineOnly: true)
    }

    private func selectPlayer(_ item: FeedItemDTO, offlineOnly: Bool) {
        NavigationTrace.log("Router selectPlayer", metadata: routerTraceMetadata(reason: "selectPlayer").merging([
            "aid": String(item.aid),
            "cid": String(item.cid),
            "bvid": item.bvid,
            "title": item.title,
            "offlineOnly": String(offlineOnly),
            "transitionWorld": "router-session",
            "transitionMode": "select-session-root",
            "transitionBoundary": "replace-current-world",
            "expectedToolbarMorph": "false",
        ]) { current, _ in current }, includeStack: true)
        replaceSession(with: .player(PlayerRoute(item: item, offlineOnly: offlineOnly)))
    }

    private func openPlayer(_ item: FeedItemDTO, offlineOnly: Bool, mode: OpenMode) {
        let activeSession = hasActiveSession
        NavigationTrace.log("Router openPlayer", metadata: routerTraceMetadata(reason: "openPlayer").merging([
            "aid": String(item.aid),
            "cid": String(item.cid),
            "bvid": item.bvid,
            "title": item.title,
            "offlineOnly": String(offlineOnly),
            "mode": "\(mode)",
            "hasActiveSession": String(activeSession),
            "transitionWorld": activeSession ? "session-host-stack" : "root-content-to-session-host",
            "transitionMode": activeSession
                ? (mode == .push ? "native-navigation-stack-push" : "replace-current-session-route")
                : "create-session-host-root",
            "transitionBoundary": activeSession ? "same-world" : "world-boundary",
            "expectedToolbarMorph": String(activeSession && mode == .push),
        ]) { current, _ in current }, includeStack: true)
        guard activeSession else {
            replaceSession(with: .player(PlayerRoute(item: item, offlineOnly: offlineOnly)))
            return
        }
        switch mode {
        case .push:
            if revealCurrentPlayerIfNeeded(matching: item, offlineOnly: offlineOnly) {
                return
            }
            appendRoute(.player(PlayerRoute(item: item, offlineOnly: offlineOnly)))
        case .replaceCurrent:
            replaceCurrentPlayer(with: item, offlineOnly: offlineOnly)
        }
    }

    func openLive(
        roomID: Int64,
        title: String = "",
        cover: String = "",
        anchorName: String = "",
        mode: OpenMode = .push
    ) {
        guard roomID > 0 else { return }
        let route = LiveRoute(roomID: roomID, title: title, cover: cover, anchorName: anchorName)
        let activeSession = hasActiveSession
        NavigationTrace.log("Router openLive", metadata: routerTraceMetadata(reason: "openLive").merging([
            "roomID": String(roomID),
            "title": title,
            "anchorName": anchorName,
            "mode": "\(mode)",
            "hasActiveSession": String(activeSession),
            "transitionWorld": activeSession ? "session-host-stack" : "root-content-to-session-host",
            "transitionMode": activeSession
                ? (mode == .push ? "native-navigation-stack-push" : "replace-current-session-route")
                : "create-session-host-root",
            "transitionBoundary": activeSession ? "same-world" : "world-boundary",
            "expectedToolbarMorph": String(activeSession && mode == .push),
        ]) { current, _ in current }, includeStack: true)
        guard activeSession else {
            replaceSession(with: .live(route))
            return
        }

        switch mode {
        case .push:
            if revealCurrentLiveIfNeeded(roomID: roomID) {
                return
            }
            appendRoute(.live(route))
        case .replaceCurrent:
            replaceCurrentLive(with: route)
        }
    }

    func selectLive(
        roomID: Int64,
        title: String = "",
        cover: String = "",
        anchorName: String = ""
    ) {
        guard roomID > 0 else { return }
        NavigationTrace.log("Router selectLive", metadata: routerTraceMetadata(reason: "selectLive").merging([
            "roomID": String(roomID),
            "title": title,
            "anchorName": anchorName,
            "transitionWorld": "router-session",
            "transitionMode": "select-session-root",
            "transitionBoundary": "replace-current-world",
            "expectedToolbarMorph": "false",
        ]) { current, _ in current }, includeStack: true)
        replaceSession(with: .live(LiveRoute(roomID: roomID, title: title, cover: cover, anchorName: anchorName)))
    }

    func openUserSpace(mid: Int64) {
        guard mid > 0 else { return }
        guard hasActiveSession else {
            NavigationTrace.log("Router openUserSpace 被忽略：无 active session", metadata: routerTraceMetadata(reason: "openUserIgnored").merging([
                "mid": String(mid),
            ]) { current, _ in current }, includeStack: true)
            return
        }
        appendRoute(.userSpace(UserSpaceRoute(mid: mid)))
    }

    func selectUserSpace(mid: Int64) {
        guard mid > 0 else { return }
        replaceSession(with: .userSpace(UserSpaceRoute(mid: mid)))
    }

    func openDynamicDetail(_ item: DynamicItemDTO) {
        guard hasActiveSession else {
            NavigationTrace.log("Router openDynamicDetail 被忽略：无 active session", metadata: routerTraceMetadata(reason: "openDynamicIgnored").merging([
                "dynamicID": item.id,
                "dynamicKind": "\(item.kind)",
            ]) { current, _ in current }, includeStack: true)
            return
        }
        appendRoute(.dynamicDetail(DynamicDetailRoute(item: item)))
    }

    func selectDynamicDetail(_ item: DynamicItemDTO) {
        replaceSession(with: .dynamicDetail(DynamicDetailRoute(item: item)))
    }

    func openArticle(id: String, kind: String = "read") {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalizedKind = kind == "opus" ? "opus" : "read"
        guard hasActiveSession else {
            NavigationTrace.log("Router openArticle 被忽略：无 active session", metadata: routerTraceMetadata(reason: "openArticleIgnored").merging([
                "articleID": trimmed,
                "kind": normalizedKind,
            ]) { current, _ in current }, includeStack: true)
            return
        }
        appendRoute(.article(ArticleRoute(articleID: trimmed, kind: normalizedKind)))
    }

    func selectArticle(id: String, kind: String = "read") {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalizedKind = kind == "opus" ? "opus" : "read"
        replaceSession(with: .article(ArticleRoute(articleID: trimmed, kind: normalizedKind)))
    }

    func openSearch(keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard hasActiveSession else {
            NavigationTrace.log("Router openSearch 被忽略：无 active session", metadata: routerTraceMetadata(reason: "openSearchIgnored").merging([
                "keyword": trimmed,
            ]) { current, _ in current }, includeStack: true)
            return
        }
        appendRoute(.search(SearchRoute(keyword: trimmed)))
    }

    func selectSearch(keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        replaceSession(with: .search(SearchRoute(keyword: trimmed)))
    }

    func openPgc(seasonID: Int64 = 0, epID: Int64 = 0, mode: OpenMode = .push) {
        guard seasonID > 0 || epID > 0 else { return }
        Task { @MainActor in
            do {
                let season = try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.pgcSeason(seasonID: seasonID, epID: epID)
                }.value
                let episode = Self.selectEpisode(from: season, epID: epID)
                guard let episode else { return }
                open(Self.makePgcFeedItem(season: season, episode: episode), mode: mode)
            } catch {
                AppLog.error("router", "PGC 路由解析失败", error: error, metadata: [
                    "seasonID": String(seasonID),
                    "epID": String(epID),
                ])
            }
        }
    }

    func selectPgc(seasonID: Int64 = 0, epID: Int64 = 0) {
        guard seasonID > 0 || epID > 0 else { return }
        Task { @MainActor in
            do {
                let season = try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.pgcSeason(seasonID: seasonID, epID: epID)
                }.value
                let episode = Self.selectEpisode(from: season, epID: epID)
                guard let episode else { return }
                select(Self.makePgcFeedItem(season: season, episode: episode))
            } catch {
                AppLog.error("router", "PGC 路由解析失败", error: error, metadata: [
                    "seasonID": String(seasonID),
                    "epID": String(epID),
                ])
            }
        }
    }

    func closeSession() {
        NavigationTrace.log("Router closeSession", metadata: routerTraceMetadata(reason: "closeSession"), includeStack: true)
        prepareCurrentRootForReplacement()
        path.removeAll()
        pending = nil
        isClosingRootSession = false
        NavigationTrace.log("Router closeSession 完成", metadata: routerTraceMetadata(reason: "closeSessionDone"), includeStack: false)
    }

    func restore(_ snapshot: SessionSnapshot) {
        NavigationTrace.log("Router restore snapshot", metadata: routerTraceMetadata(reason: "restore").merging([
            "snapshotPending": snapshot.pending?.navigationTraceSummary ?? "nil",
            "snapshotDepth": String(snapshot.path.count),
            "snapshotPath": NavigationTrace.sessionPathSummary(snapshot.path),
        ]) { current, _ in current }, includeStack: true)
        isClosingRootSession = false
        pending = snapshot.pending
        path = snapshot.path
        syncSessionAnchor()
        prunePathForPerformance()
    }

    func beginRootSessionDismissal() {
        NavigationTrace.log("Router beginRootSessionDismissal", metadata: routerTraceMetadata(reason: "beginRootDismissal"), includeStack: true)
        isClosingRootSession = true
    }

    func cancelRootSessionDismissal() {
        if isClosingRootSession {
            NavigationTrace.log("Router cancelRootSessionDismissal", metadata: routerTraceMetadata(reason: "cancelRootDismissal"), includeStack: true)
        }
        isClosingRootSession = false
    }

    func containsRoute(id: UUID) -> Bool {
        pending?.id == id || path.contains { $0.id == id }
    }

    func popLastRoute() {
        guard path.count > 1 else {
            NavigationTrace.log("Router popLastRoute 被忽略", metadata: routerTraceMetadata(reason: "popIgnored"), includeStack: true)
            return
        }
        let route = path.removeLast()
        NavigationTrace.log("Router popLastRoute", metadata: routerTraceMetadata(reason: "pop").merging([
            "removedRoute": route.navigationTraceSummary,
        ]) { current, _ in current }, includeStack: true)
        prepareRouteForDismissal(route)
        syncSessionAnchor()
        NavigationTrace.log("Router popLastRoute 完成", metadata: routerTraceMetadata(reason: "popDone"), includeStack: false)
    }

    @discardableResult
    func replacePathFromNavigation(_ newPath: [SessionRoute], allowsClosingSession: Bool = false) -> Bool {
        NavigationTrace.log("Router replacePathFromNavigation 请求", metadata: routerTraceMetadata(reason: "replacePathRequest").merging([
            "newDepth": String(newPath.count),
            "newPath": NavigationTrace.sessionPathSummary(newPath),
            "allowsClosingSession": String(allowsClosingSession),
        ]) { current, _ in current }, includeStack: true)
        if newPath.isEmpty, !allowsClosingSession, pending != nil {
            NavigationTrace.log("Router replacePathFromNavigation 被拒绝：空路径", metadata: routerTraceMetadata(reason: "replacePathRejectedEmpty").merging([
                "oldDepth": String(path.count),
                "pendingID": pending?.id.uuidString ?? "nil",
            ]) { current, _ in current }, includeStack: true)
            return false
        }
        let oldPath = path
        let removedRoutes = oldPath.filter { old in !newPath.contains(where: { $0.id == old.id }) }
        path = newPath
        for route in removedRoutes {
            prepareRouteForDismissal(route)
        }
        if path.isEmpty {
            pending = nil
            isClosingRootSession = false
        } else {
            syncSessionAnchor()
        }
        prunePathForPerformance()
        NavigationTrace.log("Router replacePathFromNavigation 完成", metadata: routerTraceMetadata(reason: "replacePathDone").merging([
            "removedRoutes": removedRoutes.map(\.navigationTraceSummary).joined(separator: " | "),
        ]) { current, _ in current }, includeStack: false)
        return true
    }

    /// Returns `.handled` if the URL was an ibili scheme and we routed
    /// it; `.systemAction` otherwise so plain `https://` links still
    /// open in Safari.
    func handle(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme?.lowercased() == "ibili" else { return .systemAction }
        NavigationTrace.log("Router handle URL", metadata: routerTraceMetadata(reason: "handleURL").merging([
            "url": url.absoluteString,
        ]) { current, _ in current }, includeStack: true)
        let host = (url.host ?? "").lowercased()
        let path = url.lastPathComponent
        switch host {
        case "bv":
            guard !path.isEmpty else { return .handled }
            open(Self.makeShell(bvid: path))
            return .handled
        case "av":
            if let aid = Int64(path) {
                open(Self.makeShell(aid: aid))
            }
            return .handled
        case "live":
            if let roomID = Int64(path) {
                openLive(roomID: roomID)
            }
            return .handled
        case "pgc", "bangumi":
            let components = url.pathComponents.filter { $0 != "/" }
            if components.count >= 2 {
                switch components[0] {
                case "ep":
                    if let epID = Int64(components[1]) { openPgc(epID: epID) }
                case "ss", "season":
                    if let seasonID = Int64(components[1]) { openPgc(seasonID: seasonID) }
                default:
                    break
                }
            } else if let epID = Self.extractFirstNumber(from: path), host == "pgc" {
                openPgc(epID: Int64(epID) ?? 0)
            }
            return .handled
        case "article":
            let components = url.pathComponents.filter { $0 != "/" }
            if components.count >= 2 {
                openOrSelectArticle(id: components[1], kind: components[0])
            }
            return .handled
        case "space", "user":
            if let mid = Int64(path) {
                if hasActiveSession {
                    openUserSpace(mid: mid)
                } else {
                    selectUserSpace(mid: mid)
                }
            }
            return .handled
        case "cv", "read":
            if let cvid = Self.extractFirstNumber(from: path) {
                openOrSelectArticle(id: cvid, kind: "read")
            }
            return .handled
        case "opus":
            if let opusID = Self.extractFirstNumber(from: path) {
                openOrSelectArticle(id: opusID, kind: "opus")
            }
            return .handled
        case "search":
            let keyword = url.queryParameters["keyword"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let keyword, !keyword.isEmpty {
                if hasActiveSession {
                    openSearch(keyword: keyword)
                } else {
                    selectSearch(keyword: keyword)
                }
            }
            return .handled
        default:
            return .handled
        }
    }

    nonisolated static func extractFirstNumber(from raw: String) -> String? {
        guard let range = raw.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return String(raw[range])
    }

    nonisolated static func makeShell(aid: Int64 = 0, bvid: String = "") -> FeedItemDTO {
        FeedItemDTO(
            aid: aid,
            bvid: bvid,
            cid: 0,
            title: "",
            cover: "",
            author: "",
            durationSec: 0,
            play: 0,
            danmaku: 0
        )
    }

    nonisolated static func selectEpisode(from season: PgcSeasonDTO, epID: Int64) -> PgcEpisodeDTO? {
        if epID > 0, let matched = season.episodes.first(where: { $0.epID == epID }) {
            return matched
        }
        return season.episodes.first
    }

    nonisolated static func makePgcFeedItem(season: PgcSeasonDTO, episode: PgcEpisodeDTO) -> FeedItemDTO {
        let seasonTitle = season.seasonTitle.isEmpty ? season.title : season.seasonTitle
        let epTitle = episode.longTitle.isEmpty ? episode.title : episode.longTitle
        let title = [seasonTitle, epTitle].filter { !$0.isEmpty }.joined(separator: " · ")
        return FeedItemDTO(
            aid: episode.aid,
            bvid: episode.bvid,
            cid: episode.cid,
            title: title.isEmpty ? seasonTitle : title,
            cover: episode.cover.isEmpty ? season.cover : episode.cover,
            author: season.upName,
            durationSec: episode.durationSec,
            play: season.stat.view,
            danmaku: season.stat.danmaku,
            epID: episode.epID,
            seasonID: season.seasonID,
            isPGC: true,
            ownerMID: season.upMID
        )
    }

    private func isCurrent(_ item: FeedItemDTO) -> Bool {
        guard let currentItem else { return false }
        return currentItem.aid == item.aid
            && currentItem.bvid == item.bvid
            && currentItem.cid == item.cid
            && currentItem.epID == item.epID
            && currentItem.isPGC == item.isPGC
    }

    private func isCurrent(_ item: FeedItemDTO, offlineOnly: Bool) -> Bool {
        guard isCurrent(item) else { return false }
        return currentRoute?.offlineOnly == offlineOnly
    }

    private func revealCurrentPlayerIfNeeded(matching item: FeedItemDTO, offlineOnly: Bool) -> Bool {
        guard isCurrent(item, offlineOnly: offlineOnly) else { return false }

        if let lastPlayerIndex = path.lastIndex(where: { $0.playerRoute != nil }) {
            let trailingIndex = path.index(after: lastPlayerIndex)
            if trailingIndex < path.endIndex {
                path.removeSubrange(trailingIndex..<path.endIndex)
            }
            syncSessionAnchor()
            return true
        }

        if !path.isEmpty {
            path.removeAll()
        }
        syncSessionAnchor()
        return true
    }

    private func replaceCurrentPlayer(with item: FeedItemDTO, offlineOnly: Bool) {
        if let lastPlayerIndex = path.lastIndex(where: { $0.playerRoute != nil }),
           case .player(let route) = path[lastPlayerIndex] {
            path[lastPlayerIndex] = .player(route.replacingItem(item).replacingOfflineOnly(offlineOnly))
            syncSessionAnchor()
            return
        }

        replaceSession(with: .player(PlayerRoute(item: item, offlineOnly: offlineOnly)))
    }

    private func revealCurrentLiveIfNeeded(roomID: Int64) -> Bool {
        let currentLive = path.reversed().compactMap(\.liveRoute).first ?? pending?.liveRoute
        guard currentLive?.roomID == roomID else { return false }

        if let lastLiveIndex = path.lastIndex(where: { $0.liveRoute != nil }) {
            let trailingIndex = path.index(after: lastLiveIndex)
            if trailingIndex < path.endIndex {
                path.removeSubrange(trailingIndex..<path.endIndex)
            }
            syncSessionAnchor()
            return true
        }

        if !path.isEmpty {
            path.removeAll()
        }
        syncSessionAnchor()
        return true
    }

    private func replaceCurrentLive(with route: LiveRoute) {
        if let lastLiveIndex = path.lastIndex(where: { $0.liveRoute != nil }) {
            path[lastLiveIndex] = .live(route)
            syncSessionAnchor()
            return
        }

        replaceSession(with: .live(route))
    }

    private func prepareCurrentRootForReplacement() {
        for route in path {
            prepareRouteForDismissal(route)
        }
    }

    private var hasActiveSession: Bool {
        pending != nil && !isClosingRootSession
    }

    private func openOrSelectArticle(id: String, kind: String) {
        if hasActiveSession {
            openArticle(id: id, kind: kind)
        } else {
            selectArticle(id: id, kind: kind)
        }
    }

    private func replaceSession(with route: SessionRoute) {
        NavigationTrace.log("Router replaceSession", metadata: routerTraceMetadata(reason: "replaceSession").merging([
            "newRoute": route.navigationTraceSummary,
            "transitionWorld": "router-session",
            "transitionMode": "session-root-replace",
            "transitionBoundary": "world-boundary-or-root-replace",
            "expectedToolbarMorph": "false",
        ]) { current, _ in current }, includeStack: true)
        prepareCurrentRootForReplacement()
        path = [route]
        pending = route.rootRoute
        isClosingRootSession = false
        prunePathForPerformance()
        NavigationTrace.log("Router replaceSession 完成", metadata: routerTraceMetadata(reason: "replaceSessionDone"), includeStack: false)
    }

    private func appendRoute(_ route: SessionRoute) {
        NavigationTrace.log("Router appendRoute", metadata: routerTraceMetadata(reason: "appendRoute").merging([
            "newRoute": route.navigationTraceSummary,
            "transitionWorld": "session-host-stack",
            "transitionMode": "native-navigation-stack-push",
            "transitionBoundary": "same-world",
            "expectedToolbarMorph": "true",
        ]) { current, _ in current }, includeStack: true)
        if path.isEmpty {
            pending = route.rootRoute
        }
        path.append(route)
        syncSessionAnchor()
        prunePathForPerformance()
        NavigationTrace.log("Router appendRoute 完成", metadata: routerTraceMetadata(reason: "appendRouteDone"), includeStack: false)
    }

    private func syncSessionAnchor() {
        pending = path.first?.rootRoute
    }

    private func routerTraceMetadata(reason: String) -> [String: String] {
        [
            "reason": reason,
            "pending": pending?.navigationTraceSummary ?? "nil",
            "pathDepth": String(path.count),
            "path": NavigationTrace.sessionPathSummary(path),
            "isClosingRootSession": String(isClosingRootSession),
        ]
    }

    private func prepareRouteForDismissal(_ route: SessionRoute) {
        switch route {
        case .player(let playerRoute):
            PlayerRuntimeCoordinator.shared.prepareForDismissal(routeID: playerRoute.id)
        case .live(let liveRoute):
            LiveRuntimeCoordinator.shared.prepareForDismissal(routeID: liveRoute.id)
        case .userSpace, .dynamicDetail, .article, .search:
            break
        }
    }

    private func prunePathForPerformance() {
        pruneExcessRoutes(
            label: "player",
            maximum: Self.maxPushedPlayerRoutes,
            routeID: { $0.playerRoute?.id }
        )
        pruneExcessRoutes(
            label: "live",
            maximum: Self.maxPushedLiveRoutes,
            routeID: { $0.liveRoute?.id }
        )
        guard path.count > Self.maxSessionPathDepth else { return }
        let removeCount = path.count - Self.maxSessionPathDepth
        let removedIDs = path.prefix(removeCount).map(\.id.uuidString).joined(separator: ",")
        path.removeFirst(removeCount)
        syncSessionAnchor()
        AppLog.info("router", "裁剪过长播放器导航栈", metadata: [
            "removed": String(removeCount),
            "remaining": String(path.count),
            "removedRouteIDs": removedIDs,
        ])
    }

    private func pruneExcessRoutes(
        label: String,
        maximum: Int,
        routeID: (SessionRoute) -> UUID?
    ) {
        guard maximum >= 0 else { return }
        let routeIndices = path.indices.filter { routeID(path[$0]) != nil }
        let overflow = routeIndices.count - maximum
        guard overflow > 0 else { return }
        let removeOffsets = Set(routeIndices.prefix(overflow))
        let removedIDs = routeIndices
            .prefix(overflow)
            .compactMap { routeID(path[$0])?.uuidString }
            .joined(separator: ",")
        path = path.enumerated()
            .filter { !removeOffsets.contains($0.offset) }
            .map { $0.element }
        syncSessionAnchor()
        AppLog.info("router", "裁剪播放器导航栈", metadata: [
            "kind": label,
            "removed": String(overflow),
            "remaining": String(routeIndices.count - overflow),
            "removedRouteIDs": removedIDs,
        ])
    }
}

extension URL {
    var queryParameters: [String: String] {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { partialResult, item in
                partialResult[item.name] = item.value ?? ""
            } ?? [:]
    }
}
