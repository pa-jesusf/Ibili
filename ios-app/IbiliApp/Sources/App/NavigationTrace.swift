import Foundation
import SwiftUI

@MainActor
enum NavigationTrace {
    private struct InteractionContext {
        let id: String
        let name: String
        let kind: String
        let metadata: [String: String]
        let startedAt: Date
    }

    private static var sequence: UInt64 = 0
    private static var activeAction: InteractionContext?
    private static var recentAction: InteractionContext?
    private static var clearRecentActionWork: DispatchWorkItem?
    private static let recentInteractionWindow: TimeInterval = 2.0

    static func withUserAction(_ name: String,
                               metadata: [String: String] = [:],
                               perform: () -> Void) {
        let previousAction = activeAction
        let context = makeContext(kind: "user-action", name: name, metadata: metadata)
        activeAction = context
        recentAction = context
        scheduleRecentActionClear()
        write("用户操作开始", metadata: contextMetadata(for: context, includeAge: false), includeStack: true)
        perform()
        write("用户操作结束", metadata: contextMetadata(for: context), includeStack: false)
        activeAction = previousAction
    }

    static func log(_ message: String,
                    metadata: [String: String] = [:],
                    includeStack: Bool = false) {
        write(message, metadata: metadata.merging(currentInteractionMetadata()) { current, _ in current }, includeStack: includeStack)
    }

    static func pageAppear(_ name: String, metadata: [String: String] = [:]) {
        log(
            "页面启动",
            metadata: ["page": name].merging(metadata) { current, _ in current },
            includeStack: true
        )
    }

    static func pageDisappear(_ name: String, metadata: [String: String] = [:]) {
        log(
            "页面消失",
            metadata: ["page": name].merging(metadata) { current, _ in current },
            includeStack: false
        )
    }

    static func sessionPathSummary(_ path: [DeepLinkRouter.SessionRoute]) -> String {
        path.map(\.navigationTraceSummary).joined(separator: " > ")
    }

    static func rootContentPathSummary(_ path: [RootContentRoute]) -> String {
        path.map(\.navigationTraceSummary).joined(separator: " > ")
    }

    private static func write(_ message: String,
                              metadata: [String: String],
                              includeStack: Bool) {
        var merged = metadata
        if includeStack, AppDiagnostics.detailedNavigationTracingEnabled {
            merged["callStack"] = callStackSummary()
        }
        AppLog.debug("navigation", message, metadata: merged)
    }

    private static func currentInteractionMetadata() -> [String: String] {
        if let activeAction {
            return contextMetadata(for: activeAction)
        }
        let now = Date()
        if let recentAction,
           now.timeIntervalSince(recentAction.startedAt) <= recentInteractionWindow {
            return contextMetadata(for: recentAction)
        }
        return ["traceSource": "system-or-unknown"]
    }

    private static func makeContext(kind: String,
                                    name: String,
                                    metadata: [String: String]) -> InteractionContext {
        sequence &+= 1
        return InteractionContext(
            id: "\(kind)-\(sequence)",
            name: name,
            kind: kind,
            metadata: metadata,
            startedAt: Date()
        )
    }

    private static func contextMetadata(for context: InteractionContext,
                                        includeAge: Bool = true) -> [String: String] {
        var metadata = context.metadata
        metadata["traceSource"] = context.kind
        metadata["traceID"] = context.id
        metadata["traceName"] = context.name
        if includeAge {
            metadata["traceAgeMs"] = String(Int(Date().timeIntervalSince(context.startedAt) * 1000))
        }
        return metadata
    }

    private static func scheduleRecentActionClear() {
        clearRecentActionWork?.cancel()
        let work = DispatchWorkItem {
            recentAction = nil
            clearRecentActionWork = nil
        }
        clearRecentActionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + recentInteractionWindow, execute: work)
    }

    private static func callStackSummary(maxFrames: Int = 12) -> String {
        Thread.callStackSymbols
            .dropFirst(3)
            .prefix(maxFrames)
            .map { frame in
                frame.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            }
            .joined(separator: " | ")
    }
}

struct NavigationPageTraceModifier: ViewModifier {
    let name: String
    let metadata: [String: String]

    func body(content: Content) -> some View {
        content
            .onAppear {
                NavigationTrace.pageAppear(name, metadata: metadata)
            }
            .onDisappear {
                NavigationTrace.pageDisappear(name, metadata: metadata)
            }
    }
}

extension View {
    func navigationTracePage(_ name: String,
                             metadata: [String: String] = [:]) -> some View {
        modifier(NavigationPageTraceModifier(name: name, metadata: metadata))
    }
}

extension DeepLinkRouter.PlayerRoute {
    var navigationContentIdentity: String {
        let item = item
        return [
            "player",
            id.uuidString,
            String(item.aid),
            item.bvid,
            String(item.cid),
            String(item.epID),
            String(item.seasonID),
            String(item.isPGC),
            String(offlineOnly),
        ].joined(separator: ":")
    }

    var navigationTraceSummary: String {
        let item = item
        return "player(id=\(id.uuidString.prefix(8)),aid=\(item.aid),cid=\(item.cid),bvid=\(item.bvid))"
    }

    var navigationTraceMetadata: [String: String] {
        [
            "routeKind": "player",
            "routeID": id.uuidString,
            "aid": String(item.aid),
            "cid": String(item.cid),
            "bvid": item.bvid,
            "title": item.title,
            "offlineOnly": String(offlineOnly),
        ]
    }
}

extension DeepLinkRouter.LiveRoute {
    var navigationContentIdentity: String {
        [
            "live",
            id.uuidString,
            String(roomID),
            title,
            cover,
            anchorName,
        ].joined(separator: ":")
    }

    var navigationTraceSummary: String {
        "live(id=\(id.uuidString.prefix(8)),roomID=\(roomID))"
    }

    var navigationTraceMetadata: [String: String] {
        [
            "routeKind": "live",
            "routeID": id.uuidString,
            "roomID": String(roomID),
            "title": title,
            "anchorName": anchorName,
        ]
    }
}

extension DeepLinkRouter.SessionRoute {
    var navigationContentIdentity: String {
        switch self {
        case .player(let route):
            return route.navigationContentIdentity
        case .live(let route):
            return route.navigationContentIdentity
        case .userSpace(let route):
            return "user:\(route.id.uuidString):\(route.mid)"
        case .dynamicDetail(let route):
            return "dynamic:\(route.id.uuidString):\(route.item.id)"
        case .article(let route):
            return "article:\(route.id.uuidString):\(route.kind):\(route.articleID)"
        case .search(let route):
            return "search:\(route.id.uuidString):\(route.keyword)"
        }
    }

    var navigationTraceSummary: String {
        switch self {
        case .player(let route):
            return route.navigationTraceSummary
        case .live(let route):
            return route.navigationTraceSummary
        case .userSpace(let route):
            return "user(id=\(route.id.uuidString.prefix(8)),mid=\(route.mid))"
        case .dynamicDetail(let route):
            return "dynamic(id=\(route.id.uuidString.prefix(8)),dynamicID=\(route.item.id))"
        case .article(let route):
            return "article(id=\(route.id.uuidString.prefix(8)),articleID=\(route.articleID),kind=\(route.kind))"
        case .search(let route):
            return "search(id=\(route.id.uuidString.prefix(8)),keyword=\(route.keyword))"
        }
    }

    var navigationTraceMetadata: [String: String] {
        switch self {
        case .player(let route):
            return route.navigationTraceMetadata
        case .live(let route):
            return route.navigationTraceMetadata
        case .userSpace(let route):
            return [
                "routeKind": "user",
                "routeID": route.id.uuidString,
                "mid": String(route.mid),
            ]
        case .dynamicDetail(let route):
            return [
                "routeKind": "dynamic",
                "routeID": route.id.uuidString,
                "dynamicID": route.item.id,
                "dynamicKind": "\(route.item.kind)",
            ]
        case .article(let route):
            return [
                "routeKind": "article",
                "routeID": route.id.uuidString,
                "articleID": route.articleID,
                "kind": route.kind,
            ]
        case .search(let route):
            return [
                "routeKind": "search",
                "routeID": route.id.uuidString,
                "keyword": route.keyword,
            ]
        }
    }
}

extension DeepLinkRouter.RootRoute {
    var navigationTraceSummary: String {
        switch self {
        case .player(let route):
            return route.navigationTraceSummary
        case .live(let route):
            return route.navigationTraceSummary
        case .userSpace(let route):
            return "user(id=\(route.id.uuidString.prefix(8)),mid=\(route.mid))"
        case .dynamicDetail(let route):
            return "dynamic(id=\(route.id.uuidString.prefix(8)),dynamicID=\(route.item.id))"
        case .article(let route):
            return "article(id=\(route.id.uuidString.prefix(8)),articleID=\(route.articleID),kind=\(route.kind))"
        case .search(let route):
            return "search(id=\(route.id.uuidString.prefix(8)),keyword=\(route.keyword))"
        }
    }
}

extension RootContentRoute {
    var navigationContentIdentity: String {
        switch self {
        case .player(let route):
            return route.navigationContentIdentity
        case .live(let route):
            return route.navigationContentIdentity
        case .userSpace(let mid):
            return "user:\(mid)"
        case .dynamicDetail(let item):
            return "dynamic:\(item.id)"
        case .article(let id, let kind):
            return "article:\(kind):\(id)"
        case .search(let keyword):
            return "search:\(keyword)"
        case .profileList(let kind):
            return "profileList:\(kind.traceName)"
        case .messageCenter:
            return "messageCenter"
        case .messageFeed(let kind):
            return "messageFeed:\(kind.rawValue)"
        }
    }

    var navigationTraceSummary: String {
        switch self {
        case .player(let route):
            return route.navigationTraceSummary
        case .live(let route):
            return route.navigationTraceSummary
        case .userSpace(let mid):
            return "user(mid=\(mid))"
        case .dynamicDetail(let item):
            return "dynamic(dynamicID=\(item.id),kind=\(item.kind))"
        case .article(let id, let kind):
            return "article(articleID=\(id),kind=\(kind))"
        case .search(let keyword):
            return "search(keyword=\(keyword))"
        case .profileList(let kind):
            return "profileList(kind=\(kind.traceName))"
        case .messageCenter:
            return "messageCenter"
        case .messageFeed(let kind):
            return "messageFeed(kind=\(kind.rawValue))"
        }
    }

    var navigationTraceMetadata: [String: String] {
        switch self {
        case .player(let route):
            return route.navigationTraceMetadata
        case .live(let route):
            return route.navigationTraceMetadata
        case .userSpace(let mid):
            return ["routeKind": "user", "mid": String(mid)]
        case .dynamicDetail(let item):
            return ["routeKind": "dynamic", "dynamicID": item.id, "dynamicKind": "\(item.kind)"]
        case .article(let id, let kind):
            return ["routeKind": "article", "articleID": id, "kind": kind]
        case .search(let keyword):
            return ["routeKind": "search", "keyword": keyword]
        case .profileList(let kind):
            return ["routeKind": "profileList", "kind": kind.traceName]
        case .messageCenter:
            return ["routeKind": "messageCenter"]
        case .messageFeed(let kind):
            return ["routeKind": "messageFeed", "kind": kind.rawValue]
        }
    }
}
