import SwiftUI
import Combine

/// Shared deep-link state. The video-detail tab handles `ibili://bv/<id>`
/// and `ibili://av/<id>` URLs emitted by `RichReplyText` jump-links.
///
/// The user comes in via SwiftUI's `OpenURLAction`; we parse and stash
/// a `FeedItemDTO` shell into `pending`. The root view observes that and
/// presents a full-screen player on top of whatever screen is currently
/// active, so jumps work uniformly from comments / descriptions / etc.
@MainActor
final class DeepLinkRouter: ObservableObject {
    struct PlayerRoute: Hashable, Identifiable {
        let id: UUID
        var item: FeedItemDTO

        init(id: UUID = UUID(), item: FeedItemDTO) {
            self.id = id
            self.item = item
        }

        func replacingItem(_ item: FeedItemDTO) -> Self {
            Self(id: id, item: item)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
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
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
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

    enum SessionRoute: Hashable, Identifiable {
        case player(PlayerRoute)
        case live(LiveRoute)
        case userSpace(UserSpaceRoute)
        case dynamicDetail(DynamicDetailRoute)
        case article(ArticleRoute)

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

    enum RootRoute: Hashable, Identifiable {
        case player(PlayerRoute)
        case live(LiveRoute)
        case article(ArticleRoute)

        var id: UUID {
            switch self {
            case .player(let route):
                return route.id
            case .live(let route):
                return route.id
            case .article(let route):
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
    /// Navigation path inside the active player session. The root
    /// player is rendered when `pending != nil`; subsequent pushes
    /// (related video tap, season episode, user-space-tap-then-play)
    /// append to this path so the user gets a real
    /// "from where you came, back to where you came" stack.
    ///
    /// Anything that wants to route to another player should go
    /// through `open(_:mode:)` so the navigation semantics stay
    /// uniform across every entry point.
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

    var snapshot: SessionSnapshot {
        SessionSnapshot(pending: pending, path: path)
    }

    func open(_ item: FeedItemDTO, mode: OpenMode = .push) {
        guard pending != nil, !isClosingRootSession else {
            path.removeAll()
            isClosingRootSession = false
            pending = .player(PlayerRoute(item: item))
            return
        }

        switch mode {
        case .push:
            if revealCurrentPlayerIfNeeded(matching: item) {
                return
            }
            path.append(.player(PlayerRoute(item: item)))
        case .replaceCurrent:
            replaceCurrentPlayer(with: item)
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
        guard pending != nil, !isClosingRootSession else {
            path.removeAll()
            isClosingRootSession = false
            pending = .live(route)
            return
        }

        switch mode {
        case .push:
            if revealCurrentLiveIfNeeded(roomID: roomID) {
                return
            }
            path.append(.live(route))
        case .replaceCurrent:
            replaceCurrentLive(with: route)
        }
    }

    func openUserSpace(mid: Int64) {
        guard pending != nil, mid > 0 else { return }
        path.append(.userSpace(UserSpaceRoute(mid: mid)))
    }

    func openDynamicDetail(_ item: DynamicItemDTO) {
        guard pending != nil else { return }
        path.append(.dynamicDetail(DynamicDetailRoute(item: item)))
    }

    func openArticle(id: String, kind: String = "read") {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalizedKind = kind == "opus" ? "opus" : "read"
        let route = ArticleRoute(articleID: trimmed, kind: normalizedKind)
        guard pending != nil, !isClosingRootSession else {
            path.removeAll()
            isClosingRootSession = false
            pending = .article(route)
            return
        }
        path.append(.article(route))
    }

    func openPgc(seasonID: Int64 = 0, epID: Int64 = 0, mode: OpenMode = .push) {
        guard seasonID > 0 || epID > 0 else { return }
        Task { @MainActor in
            do {
                let season = try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.pgcSeason(seasonID: seasonID, epID: epID)
                }.value
                let episode = selectEpisode(from: season, epID: epID)
                guard let episode else { return }
                open(makePgcFeedItem(season: season, episode: episode), mode: mode)
            } catch {
                AppLog.error("router", "PGC 路由解析失败", error: error, metadata: [
                    "seasonID": String(seasonID),
                    "epID": String(epID),
                ])
            }
        }
    }

    func closeSession() {
        path.removeAll()
        pending = nil
        isClosingRootSession = false
    }

    func restore(_ snapshot: SessionSnapshot) {
        isClosingRootSession = false
        pending = snapshot.pending
        path = snapshot.path
    }

    func beginRootSessionDismissal() {
        isClosingRootSession = true
    }

    func cancelRootSessionDismissal() {
        isClosingRootSession = false
    }

    func containsRoute(id: UUID) -> Bool {
        pending?.id == id || path.contains { $0.id == id }
    }

    /// Returns `.handled` if the URL was an ibili scheme and we routed
    /// it; `.systemAction` otherwise so plain `https://` links still
    /// open in Safari.
    func handle(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme?.lowercased() == "ibili" else { return .systemAction }
        let host = (url.host ?? "").lowercased()
        let path = url.lastPathComponent
        switch host {
        case "bv":
            guard !path.isEmpty else { return .handled }
            open(makeShell(bvid: path))
            return .handled
        case "av":
            if let aid = Int64(path) {
                open(makeShell(aid: aid))
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
                openArticle(id: components[1], kind: components[0])
            }
            return .handled
        case "space", "user":
            if let mid = Int64(path) {
                openUserSpace(mid: mid)
            }
            return .handled
        case "cv", "read":
            if let cvid = Self.extractFirstNumber(from: path) {
                openArticle(id: cvid, kind: "read")
            }
            return .handled
        case "opus":
            if let opusID = Self.extractFirstNumber(from: path) {
                openArticle(id: opusID, kind: "opus")
            }
            return .handled
        default:
            return .handled
        }
    }

    private static func extractFirstNumber(from raw: String) -> String? {
        guard let range = raw.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return String(raw[range])
    }

    private func makeShell(aid: Int64 = 0, bvid: String = "") -> FeedItemDTO {
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

    private func selectEpisode(from season: PgcSeasonDTO, epID: Int64) -> PgcEpisodeDTO? {
        if epID > 0, let matched = season.episodes.first(where: { $0.epID == epID }) {
            return matched
        }
        return season.episodes.first
    }

    private func makePgcFeedItem(season: PgcSeasonDTO, episode: PgcEpisodeDTO) -> FeedItemDTO {
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
            isPGC: true
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

    private func revealCurrentPlayerIfNeeded(matching item: FeedItemDTO) -> Bool {
        guard isCurrent(item) else { return false }

        if let lastPlayerIndex = path.lastIndex(where: { $0.playerRoute != nil }) {
            let trailingIndex = path.index(after: lastPlayerIndex)
            if trailingIndex < path.endIndex {
                path.removeSubrange(trailingIndex..<path.endIndex)
            }
            return true
        }

        if !path.isEmpty {
            path.removeAll()
        }
        return true
    }

    private func replaceCurrentPlayer(with item: FeedItemDTO) {
        if let lastPlayerIndex = path.lastIndex(where: { $0.playerRoute != nil }),
           case .player(let route) = path[lastPlayerIndex] {
            path[lastPlayerIndex] = .player(route.replacingItem(item))
            return
        }

        if let pendingPlayer = pending?.playerRoute {
            pending = .player(pendingPlayer.replacingItem(item))
        } else {
            pending = .player(PlayerRoute(item: item))
        }
    }

    private func revealCurrentLiveIfNeeded(roomID: Int64) -> Bool {
        let currentLive = path.reversed().compactMap(\.liveRoute).first ?? pending?.liveRoute
        guard currentLive?.roomID == roomID else { return false }

        if let lastLiveIndex = path.lastIndex(where: { $0.liveRoute != nil }) {
            let trailingIndex = path.index(after: lastLiveIndex)
            if trailingIndex < path.endIndex {
                path.removeSubrange(trailingIndex..<path.endIndex)
            }
            return true
        }

        if !path.isEmpty {
            path.removeAll()
        }
        return true
    }

    private func replaceCurrentLive(with route: LiveRoute) {
        if let lastLiveIndex = path.lastIndex(where: { $0.liveRoute != nil }) {
            path[lastLiveIndex] = .live(route)
            return
        }

        pending = .live(route)
    }
}
