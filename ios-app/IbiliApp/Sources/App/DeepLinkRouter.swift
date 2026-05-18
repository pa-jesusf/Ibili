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

    struct SearchRoute: Hashable, Identifiable {
        let id: UUID
        let keyword: String

        init(id: UUID = UUID(), keyword: String) {
            self.id = id
            self.keyword = keyword
        }
    }

    struct AnimeSubjectRoute: Hashable, Identifiable {
        let id: UUID
        let subjectID: Int64
        let initialSubject: AnimeSubjectDTO?

        init(id: UUID = UUID(), subjectID: Int64, initialSubject: AnimeSubjectDTO? = nil) {
            self.id = id
            self.subjectID = subjectID
            self.initialSubject = initialSubject
        }
    }

    struct AnimePlayerRoute: Hashable, Identifiable {
        let id: UUID
        let subject: AnimeSubjectDTO
        let episode: AnimeEpisodeDTO
        let initialPlay: AnimePlayUrlDTO?

        init(id: UUID = UUID(), subject: AnimeSubjectDTO, episode: AnimeEpisodeDTO, initialPlay: AnimePlayUrlDTO? = nil) {
            self.id = id
            self.subject = subject
            self.episode = episode
            self.initialPlay = initialPlay
        }
    }

    enum SessionRoute: Hashable, Identifiable {
        case player(PlayerRoute)
        case live(LiveRoute)
        case userSpace(UserSpaceRoute)
        case dynamicDetail(DynamicDetailRoute)
        case article(ArticleRoute)
        case search(SearchRoute)
        case animeSubject(AnimeSubjectRoute)
        case animePlayer(AnimePlayerRoute)

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
            case .animeSubject(let route):
                return route.id
            case .animePlayer(let route):
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
        case dynamicDetail(DynamicDetailRoute)
        case userSpace(UserSpaceRoute)
        case article(ArticleRoute)
        case search(SearchRoute)
        case animeSubject(AnimeSubjectRoute)
        case animePlayer(AnimePlayerRoute)

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
            case .animeSubject(let route):
                return route.id
            case .animePlayer(let route):
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

        var usesOwnPlayerHostToolbar: Bool {
            switch self {
            case .animePlayer:
                return true
            case .player, .live, .dynamicDetail, .userSpace, .article, .search, .animeSubject:
                return false
            }
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
        prepareCurrentRootForReplacement()
        path.removeAll()
        isClosingRootSession = false
        pending = .player(PlayerRoute(item: item, offlineOnly: offlineOnly))
    }

    private func openPlayer(_ item: FeedItemDTO, offlineOnly: Bool, mode: OpenMode) {
        guard pending != nil, !isClosingRootSession else {
            path.removeAll()
            isClosingRootSession = false
            pending = .player(PlayerRoute(item: item, offlineOnly: offlineOnly))
            return
        }

        switch mode {
        case .push:
            if revealCurrentPlayerIfNeeded(matching: item, offlineOnly: offlineOnly) {
                return
            }
            path.append(.player(PlayerRoute(item: item, offlineOnly: offlineOnly)))
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

    func selectLive(
        roomID: Int64,
        title: String = "",
        cover: String = "",
        anchorName: String = ""
    ) {
        guard roomID > 0 else { return }
        prepareCurrentRootForReplacement()
        path.removeAll()
        isClosingRootSession = false
        pending = .live(LiveRoute(roomID: roomID, title: title, cover: cover, anchorName: anchorName))
    }

    func openUserSpace(mid: Int64) {
        guard pending != nil, mid > 0 else { return }
        path.append(.userSpace(UserSpaceRoute(mid: mid)))
    }

    func selectUserSpace(mid: Int64) {
        guard mid > 0 else { return }
        prepareCurrentRootForReplacement()
        path.removeAll()
        isClosingRootSession = false
        pending = .userSpace(UserSpaceRoute(mid: mid))
    }

    func openDynamicDetail(_ item: DynamicItemDTO) {
        guard pending != nil else { return }
        path.append(.dynamicDetail(DynamicDetailRoute(item: item)))
    }

    func selectDynamicDetail(_ item: DynamicItemDTO) {
        prepareCurrentRootForReplacement()
        path.removeAll()
        isClosingRootSession = false
        pending = .dynamicDetail(DynamicDetailRoute(item: item))
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

    func selectArticle(id: String, kind: String = "read") {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalizedKind = kind == "opus" ? "opus" : "read"
        prepareCurrentRootForReplacement()
        path.removeAll()
        isClosingRootSession = false
        pending = .article(ArticleRoute(articleID: trimmed, kind: normalizedKind))
    }

    func openSearch(keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let route = SearchRoute(keyword: trimmed)
        guard pending != nil, !isClosingRootSession else {
            path.removeAll()
            isClosingRootSession = false
            pending = .search(route)
            return
        }
        path.append(.search(route))
    }

    func selectSearch(keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        prepareCurrentRootForReplacement()
        path.removeAll()
        isClosingRootSession = false
        pending = .search(SearchRoute(keyword: trimmed))
    }

    func openAnimeSubject(_ subject: AnimeSubjectDTO, mode: OpenMode = .push) {
        openAnimeSubject(subjectID: subject.id, initialSubject: subject, mode: mode)
    }

    func openAnimeSubject(subjectID: Int64, initialSubject: AnimeSubjectDTO? = nil, mode: OpenMode = .push) {
        guard subjectID > 0 else { return }
        let route = AnimeSubjectRoute(subjectID: subjectID, initialSubject: initialSubject)
        guard pending != nil, !isClosingRootSession else {
            path.removeAll()
            isClosingRootSession = false
            pending = .animeSubject(route)
            return
        }
        switch mode {
        case .push:
            path.append(.animeSubject(route))
        case .replaceCurrent:
            replaceCurrentGeneric(with: .animeSubject(route), root: .animeSubject(route))
        }
    }

    func selectAnimeSubject(_ subject: AnimeSubjectDTO) {
        guard subject.id > 0 else { return }
        prepareCurrentRootForReplacement()
        path.removeAll()
        isClosingRootSession = false
        pending = .animeSubject(AnimeSubjectRoute(subjectID: subject.id, initialSubject: subject))
    }

    func openAnimePlayer(play: AnimePlayUrlDTO, subject: AnimeSubjectDTO, episode: AnimeEpisodeDTO, mode: OpenMode = .push) {
        let route = AnimePlayerRoute(subject: subject, episode: episode, initialPlay: play)
        guard pending != nil, !isClosingRootSession else {
            path.removeAll()
            isClosingRootSession = false
            pending = .animePlayer(route)
            return
        }
        switch mode {
        case .push:
            path.append(.animePlayer(route))
        case .replaceCurrent:
            replaceCurrentGeneric(with: .animePlayer(route), root: .animePlayer(route))
        }
    }

    func selectAnimePlayer(play: AnimePlayUrlDTO, subject: AnimeSubjectDTO, episode: AnimeEpisodeDTO) {
        prepareCurrentRootForReplacement()
        path.removeAll()
        isClosingRootSession = false
        pending = .animePlayer(AnimePlayerRoute(subject: subject, episode: episode, initialPlay: play))
    }

    func openAnimeEpisode(subject: AnimeSubjectDTO, episode: AnimeEpisodeDTO, mode: OpenMode = .push) {
        let route = AnimePlayerRoute(subject: subject, episode: episode)
        guard pending != nil, !isClosingRootSession else {
            path.removeAll()
            isClosingRootSession = false
            pending = .animePlayer(route)
            return
        }
        switch mode {
        case .push:
            path.append(.animePlayer(route))
        case .replaceCurrent:
            replaceCurrentGeneric(with: .animePlayer(route), root: .animePlayer(route))
        }
    }

    func selectAnimeEpisode(subject: AnimeSubjectDTO, episode: AnimeEpisodeDTO) {
        prepareCurrentRootForReplacement()
        path.removeAll()
        isClosingRootSession = false
        pending = .animePlayer(AnimePlayerRoute(subject: subject, episode: episode))
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

    func selectPgc(seasonID: Int64 = 0, epID: Int64 = 0) {
        guard seasonID > 0 || epID > 0 else { return }
        Task { @MainActor in
            do {
                let season = try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.pgcSeason(seasonID: seasonID, epID: epID)
                }.value
                let episode = selectEpisode(from: season, epID: epID)
                guard let episode else { return }
                select(makePgcFeedItem(season: season, episode: episode))
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
        case "search":
            let keyword = url.queryParameters["keyword"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let keyword, !keyword.isEmpty {
                openSearch(keyword: keyword)
            }
            return .handled
        case "anime", "subject":
            if let subjectID = Int64(path) {
                openAnimeSubject(subjectID: subjectID)
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
            return true
        }

        if !path.isEmpty {
            path.removeAll()
        }
        return true
    }

    private func replaceCurrentPlayer(with item: FeedItemDTO, offlineOnly: Bool) {
        if let lastPlayerIndex = path.lastIndex(where: { $0.playerRoute != nil }),
           case .player(let route) = path[lastPlayerIndex] {
            path[lastPlayerIndex] = .player(route.replacingItem(item).replacingOfflineOnly(offlineOnly))
            return
        }

        if let pendingPlayer = pending?.playerRoute {
            pending = .player(pendingPlayer.replacingItem(item).replacingOfflineOnly(offlineOnly))
        } else {
            pending = .player(PlayerRoute(item: item, offlineOnly: offlineOnly))
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

    private func prepareCurrentRootForReplacement() {
        for route in path {
            switch route {
            case .player(let playerRoute):
                PlayerRuntimeCoordinator.shared.prepareForDismissal(routeID: playerRoute.id)
            case .live(let liveRoute):
                LiveRuntimeCoordinator.shared.prepareForDismissal(routeID: liveRoute.id)
            case .userSpace, .dynamicDetail, .article, .search, .animeSubject, .animePlayer:
                break
            }
        }
        switch pending {
        case .player(let playerRoute):
            PlayerRuntimeCoordinator.shared.prepareForDismissal(routeID: playerRoute.id)
        case .live(let liveRoute):
            LiveRuntimeCoordinator.shared.prepareForDismissal(routeID: liveRoute.id)
        case .dynamicDetail, .userSpace, .article, .search, .animeSubject, .animePlayer, nil:
            break
        }
    }

    private func replaceCurrentGeneric(with route: SessionRoute, root: RootRoute) {
        if !path.isEmpty {
            path[path.index(before: path.endIndex)] = route
        } else {
            pending = root
        }
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
