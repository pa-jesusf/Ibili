import SwiftUI

enum RootContentRoute: Hashable {
    case player(DeepLinkRouter.PlayerRoute)
    case live(DeepLinkRouter.LiveRoute)
    case userSpace(mid: Int64)
    case dynamicDetail(DynamicItemDTO)
    case article(id: String, kind: String)
    case search(keyword: String)

    var playerRoute: DeepLinkRouter.PlayerRoute? {
        guard case .player(let route) = self else { return nil }
        return route
    }

    var liveRoute: DeepLinkRouter.LiveRoute? {
        guard case .live(let route) = self else { return nil }
        return route
    }

    var sessionRoute: DeepLinkRouter.SessionRoute {
        switch self {
        case .player(let route):
            return .player(route)
        case .live(let route):
            return .live(route)
        case .userSpace(let mid):
            return .userSpace(DeepLinkRouter.UserSpaceRoute(mid: mid))
        case .dynamicDetail(let item):
            return .dynamicDetail(DeepLinkRouter.DynamicDetailRoute(item: item))
        case .article(let id, let kind):
            return .article(DeepLinkRouter.ArticleRoute(articleID: id, kind: kind))
        case .search(let keyword):
            return .search(DeepLinkRouter.SearchRoute(keyword: keyword))
        }
    }

    init(sessionRoute: DeepLinkRouter.SessionRoute) {
        switch sessionRoute {
        case .player(let route):
            self = .player(route)
        case .live(let route):
            self = .live(route)
        case .userSpace(let route):
            self = .userSpace(mid: route.mid)
        case .dynamicDetail(let route):
            self = .dynamicDetail(route.item)
        case .article(let route):
            self = .article(id: route.articleID, kind: route.kind)
        case .search(let route):
            self = .search(keyword: route.keyword)
        }
    }
}

struct RootContentNavigationActions {
    var open: (RootContentRoute) -> Void = { _ in }
    var replaceCurrent: (RootContentRoute) -> Void = { _ in }

    @MainActor
    func openPlayer(_ item: FeedItemDTO,
                    offlineOnly: Bool = false,
                    mode: DeepLinkRouter.OpenMode = .push) {
        NavigationTrace.log("根内容导航请求", metadata: [
            "request": "openPlayer",
            "aid": String(item.aid),
            "cid": String(item.cid),
            "bvid": item.bvid,
            "title": item.title,
            "offlineOnly": String(offlineOnly),
            "mode": "\(mode)",
            "transitionWorld": "root-content",
            "transitionMode": "intent",
        ], includeStack: true)
        let route = RootContentRoute.player(DeepLinkRouter.PlayerRoute(item: item, offlineOnly: offlineOnly))
        switch mode {
        case .push:
            open(route)
        case .replaceCurrent:
            replaceCurrent(route)
        }
    }

    @MainActor
    func openLive(roomID: Int64, title: String = "", cover: String = "", anchorName: String = "") {
        guard roomID > 0 else { return }
        NavigationTrace.log("根内容导航请求", metadata: [
            "request": "openLive",
            "roomID": String(roomID),
            "title": title,
            "anchorName": anchorName,
            "transitionWorld": "root-content",
            "transitionMode": "intent",
        ], includeStack: true)
        open(.live(DeepLinkRouter.LiveRoute(
            roomID: roomID,
            title: title,
            cover: cover,
            anchorName: anchorName
        )))
    }

    @MainActor
    func openUserSpace(mid: Int64) {
        guard mid > 0 else { return }
        NavigationTrace.log("根内容导航请求", metadata: [
            "request": "openUserSpace",
            "mid": String(mid),
            "transitionWorld": "root-content",
            "transitionMode": "intent",
        ], includeStack: true)
        open(.userSpace(mid: mid))
    }

    @MainActor
    func openDynamicDetail(_ item: DynamicItemDTO) {
        NavigationTrace.log("根内容导航请求", metadata: [
            "request": "openDynamicDetail",
            "dynamicID": item.id,
            "dynamicKind": "\(item.kind)",
            "transitionWorld": "root-content",
            "transitionMode": "intent",
        ], includeStack: true)
        open(.dynamicDetail(item))
    }

    @MainActor
    func openArticle(id: String, kind: String = "read") {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NavigationTrace.log("根内容导航请求", metadata: [
            "request": "openArticle",
            "articleID": trimmed,
            "kind": kind,
            "transitionWorld": "root-content",
            "transitionMode": "intent",
        ], includeStack: true)
        open(.article(id: trimmed, kind: kind == "opus" ? "opus" : "read"))
    }

    @MainActor
    func openSearch(keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NavigationTrace.log("根内容导航请求", metadata: [
            "request": "openSearch",
            "keyword": trimmed,
            "transitionWorld": "root-content",
            "transitionMode": "intent",
        ], includeStack: true)
        open(.search(keyword: trimmed))
    }

    @MainActor
    func openPgc(seasonID: Int64 = 0, epID: Int64 = 0) {
        guard seasonID > 0 || epID > 0 else { return }
        Task { @MainActor in
            do {
                let season = try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.pgcSeason(seasonID: seasonID, epID: epID)
                }.value
                let episode = DeepLinkRouter.selectEpisode(from: season, epID: epID)
                guard let episode else { return }
                openPlayer(DeepLinkRouter.makePgcFeedItem(season: season, episode: episode))
            } catch {
                AppLog.error("navigation", "根内容 PGC 路由解析失败", error: error, metadata: [
                    "seasonID": String(seasonID),
                    "epID": String(epID),
                ])
            }
        }
    }

    @MainActor
    func handle(_ url: URL, router: DeepLinkRouter) -> OpenURLAction.Result {
        guard url.scheme?.lowercased() == "ibili" else { return .systemAction }
        NavigationTrace.log("根内容 openURL", metadata: [
            "url": url.absoluteString,
            "transitionWorld": "root-content",
            "transitionMode": "open-url",
        ], includeStack: true)
        let host = (url.host ?? "").lowercased()
        let path = url.lastPathComponent
        switch host {
        case "bv":
            guard !path.isEmpty else { return .handled }
            openPlayer(DeepLinkRouter.makeShell(bvid: path))
            return .handled
        case "av":
            if let aid = Int64(path) {
                openPlayer(DeepLinkRouter.makeShell(aid: aid))
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
            } else if let epID = DeepLinkRouter.extractFirstNumber(from: path), host == "pgc" {
                openPgc(epID: Int64(epID) ?? 0)
            }
            return .handled
        case "space", "user":
            if let mid = Int64(path) {
                openUserSpace(mid: mid)
            }
            return .handled
        case "article":
            let components = url.pathComponents.filter { $0 != "/" }
            if components.count >= 2 {
                openArticle(id: components[1], kind: components[0])
            }
            return .handled
        case "cv", "read":
            if let cvid = DeepLinkRouter.extractFirstNumber(from: path) {
                openArticle(id: cvid, kind: "read")
            }
            return .handled
        case "opus":
            if let opusID = DeepLinkRouter.extractFirstNumber(from: path) {
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
        default:
            return router.handle(url)
        }
    }
}

private struct RootContentNavigationActionsKey: EnvironmentKey {
    static let defaultValue = RootContentNavigationActions()
}

extension EnvironmentValues {
    var rootContentNavigation: RootContentNavigationActions {
        get { self[RootContentNavigationActionsKey.self] }
        set { self[RootContentNavigationActionsKey.self] = newValue }
    }
}

struct RootContentNavigationStack<Root: View>: View {
    @EnvironmentObject private var router: DeepLinkRouter
    @EnvironmentObject private var presentationGuard: PlayerPresentationNavigationGuard
    @Binding private var path: [RootContentRoute]
    private let name: String
    private let onMediaRoutesChanged: () -> Void
    private let root: () -> Root

    init(
        name: String = "unknown",
        path: Binding<[RootContentRoute]>,
        onMediaRoutesChanged: @escaping () -> Void = {},
        @ViewBuilder root: @escaping () -> Root
    ) {
        self.name = name
        _path = path
        self.onMediaRoutesChanged = onMediaRoutesChanged
        self.root = root
    }

    var body: some View {
        let navigation = actions
        NavigationStack(path: controlledPath) {
            root()
                .environment(\.rootContentNavigation, navigation)
                .navigationTracePage("RootContent:\(name)", metadata: rootTraceMetadata)
                .navigationDestination(for: RootContentRoute.self) { route in
                    destinationView(for: route)
                        .environment(\.rootContentNavigation, navigation)
                        .navigationTracePage("RootContentRoute", metadata: route.navigationTraceMetadata.merging([
                            "stack": name,
                            "route": route.navigationTraceSummary,
                        ]) { current, _ in current })
                }
        }
        .environment(\.openURL, OpenURLAction { url in
            navigation.handle(url, router: router)
        })
        .environment(\.beginNativePlayerFullscreenExit, presentationGuard.beginNativeFullscreenExitProtection)
        .environment(\.endNativePlayerFullscreenExit, presentationGuard.endNativeFullscreenExitProtection)
        .onAppear {
            syncMediaSessions()
        }
        .onChange(of: path.map(\.navigationContentIdentity)) { _ in
            syncMediaSessions()
        }
    }

    private var actions: RootContentNavigationActions {
        RootContentNavigationActions(
            open: { route in
                NavigationTrace.log("根内容导航 append", metadata: [
                    "stack": name,
                    "route": route.navigationTraceSummary,
                    "oldDepth": String(path.count),
                    "transitionWorld": "root-content-stack",
                    "transitionMode": "native-navigation-stack-push",
                    "transitionBoundary": "same-world",
                    "expectedToolbarMorph": "true",
                ].merging(route.navigationTraceMetadata) { current, _ in current }, includeStack: true)
                path.append(route)
                syncMediaSessions()
            },
            replaceCurrent: { route in
                replaceCurrentRoute(with: route)
            }
        )
    }

    private var controlledPath: Binding<[RootContentRoute]> {
        Binding(
            get: { path },
            set: { newPath in
                let oldPath = path
                let accepted = presentationGuard.shouldAcceptPathChange(
                    from: oldPath.map(\.sessionRoute),
                    to: newPath.map(\.sessionRoute)
                )
                NavigationTrace.log(accepted ? "根内容 NavigationStack path 写回" : "根内容 NavigationStack path 写回被拒绝", metadata: [
                    "stack": name,
                    "oldDepth": String(path.count),
                    "newDepth": String(newPath.count),
                    "oldPath": NavigationTrace.rootContentPathSummary(path),
                    "newPath": NavigationTrace.rootContentPathSummary(newPath),
                ], includeStack: true)
                guard accepted else { return }
                path = newPath
                prepareRemovedMediaRoutes(from: oldPath, to: newPath)
                syncMediaSessions()
            }
        )
    }

    @ViewBuilder
    private func destinationView(for route: RootContentRoute) -> some View {
        switch route {
        case .player(let playerRoute):
            DeepLinkRouteContent.playerDestination(
                for: playerRoute,
                onPictureInPictureActiveChange: { isActive, routeID in
                    handlePictureInPictureChange(isActive, routeID: routeID)
                },
                onPictureInPictureRestore: { routeID, completion in
                    restorePictureInPicture(routeID: routeID, completion: completion)
                }
            )
            .id(playerRoute.navigationContentIdentity)
            .toolbar(.hidden, for: .tabBar)
        case .live(let liveRoute):
            DeepLinkRouteContent.liveDestination(for: liveRoute)
                .id(liveRoute.navigationContentIdentity)
                .toolbar(.hidden, for: .tabBar)
        case .userSpace(let mid):
            UserSpaceView(mid: mid)
        case .dynamicDetail(let item):
            DynamicDetailView(item: item)
        case .article(let id, let kind):
            ArticleView(articleID: id, kind: kind)
        case .search(let keyword):
            SearchRouteView(keyword: keyword)
        }
    }

    private func handlePictureInPictureChange(_ isActive: Bool, routeID: UUID) {
        PlayerRuntimeCoordinator.shared.handle(.pictureInPictureChanged(isActive), for: routeID)
        PlayerRuntimeCoordinator.shared.setPictureInPictureActive(
            isActive,
            for: routeID,
            snapshot: isActive ? DeepLinkRouter.SessionSnapshot(
                pending: path.first?.sessionRoute.rootRoute,
                path: path.map(\.sessionRoute)
            ) : nil
        )
        syncMediaSessions()
    }

    private func restorePictureInPicture(routeID: UUID, completion: @escaping (Bool) -> Void) {
        if path.contains(where: { $0.playerRoute?.id == routeID }) {
            completion(true)
            return
        }

        if let snapshot = PlayerRuntimeCoordinator.shared.pictureInPictureSnapshot(for: routeID) {
            path = snapshot.path.map(RootContentRoute.init(sessionRoute:))
            syncMediaSessions()
            completion(path.contains(where: { $0.playerRoute?.id == routeID }))
            return
        }

        completion(false)
    }

    private func syncMediaSessions() {
        onMediaRoutesChanged()
    }

    private func prepareRemovedMediaRoutes(from oldPath: [RootContentRoute], to newPath: [RootContentRoute]) {
        let newIDs = Set(newPath.map(\.navigationIdentity))
        for route in oldPath where !newIDs.contains(route.navigationIdentity) {
            prepareMediaRouteForDismissal(route)
        }
    }

    private func prepareMediaRouteForDismissal(_ route: RootContentRoute) {
        switch route {
        case .player(let playerRoute):
            PlayerRuntimeCoordinator.shared.prepareForDismissal(routeID: playerRoute.id)
        case .live(let liveRoute):
            LiveRuntimeCoordinator.shared.prepareForDismissal(routeID: liveRoute.id)
        case .userSpace, .dynamicDetail, .article, .search:
            break
        }
    }

    private func replaceCurrentRoute(with route: RootContentRoute) {
        let oldPath = path
        let replacement = preservingCurrentMediaSessionIfPossible(for: route)
        NavigationTrace.log("根内容导航 replace current", metadata: [
            "stack": name,
            "route": replacement.navigationTraceSummary,
            "oldDepth": String(path.count),
            "transitionWorld": "root-content-stack",
            "transitionMode": "replace-current-root-content-route",
            "transitionBoundary": "same-world",
            "expectedToolbarMorph": "false",
        ].merging(replacement.navigationTraceMetadata) { current, _ in current }, includeStack: true)
        if path.isEmpty {
            path.append(replacement)
        } else {
            path[path.index(before: path.endIndex)] = replacement
        }
        prepareRemovedMediaRoutes(from: oldPath, to: path)
        syncMediaSessions()
    }

    private func preservingCurrentMediaSessionIfPossible(for route: RootContentRoute) -> RootContentRoute {
        switch (path.last, route) {
        case (.player(let oldRoute), .player(let newRoute)):
            return .player(oldRoute.replacingItem(newRoute.item).replacingOfflineOnly(newRoute.offlineOnly))
        case (.live(let oldRoute), .live(let newRoute)):
            return .live(oldRoute.replacingMetadata(
                title: newRoute.title,
                cover: newRoute.cover,
                anchorName: newRoute.anchorName
            ))
        default:
            return route
        }
    }

    private var rootTraceMetadata: [String: String] {
        [
            "stack": name,
            "pathDepth": String(path.count),
            "path": NavigationTrace.rootContentPathSummary(path),
        ]
    }
}

extension RootContentRoute {
    var navigationIdentity: String {
        switch self {
        case .player(let route):
            return "player:\(route.id.uuidString)"
        case .live(let route):
            return "live:\(route.id.uuidString)"
        case .userSpace(let mid):
            return "user:\(mid)"
        case .dynamicDetail(let item):
            return "dynamic:\(item.id)"
        case .article(let id, let kind):
            return "article:\(kind):\(id)"
        case .search(let keyword):
            return "search:\(keyword)"
        }
    }
}
