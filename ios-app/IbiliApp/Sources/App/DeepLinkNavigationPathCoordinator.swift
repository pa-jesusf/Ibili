import Foundation

enum DeepLinkNavigationPathCoordinator {
    @MainActor
    static func shouldApply(
        displayedPath: [DeepLinkRouter.SessionRoute],
        routerPath: [DeepLinkRouter.SessionRoute],
        newPath: [DeepLinkRouter.SessionRoute],
        navigationGuard: PlayerPresentationNavigationGuard
    ) -> Bool {
        let displayedIDs = displayedPath.map(\.id)
        let newIDs = newPath.map(\.id)
        guard displayedIDs != newIDs else {
            NavigationTrace.log("导航栈 path 写回被拒绝：重复写入", metadata: [
                "displayedDepth": String(displayedPath.count),
                "newDepth": String(newPath.count),
                "displayedPath": NavigationTrace.sessionPathSummary(displayedPath),
                "newPath": NavigationTrace.sessionPathSummary(newPath),
            ], includeStack: true)
            return false
        }

        if newPath.isEmpty, !routerPath.isEmpty {
            NavigationTrace.log("导航栈 path 写回被拒绝：初始化空路径", metadata: [
                "displayedDepth": String(displayedPath.count),
                "routerDepth": String(routerPath.count),
                "newDepth": String(newPath.count),
                "displayedPath": NavigationTrace.sessionPathSummary(displayedPath),
                "routerPath": NavigationTrace.sessionPathSummary(routerPath),
            ], includeStack: true)
            return false
        }

        return navigationGuard.shouldAcceptPathChange(from: displayedPath, to: newPath)
    }
}
