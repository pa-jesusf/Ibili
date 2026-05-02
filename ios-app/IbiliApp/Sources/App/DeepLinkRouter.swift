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

    enum SessionRoute: Hashable, Identifiable {
        case player(PlayerRoute)
        case userSpace(UserSpaceRoute)
        case dynamicDetail(DynamicDetailRoute)

        var id: UUID {
            switch self {
            case .player(let route):
                return route.id
            case .userSpace(let route):
                return route.id
            case .dynamicDetail(let route):
                return route.id
            }
        }

        var playerRoute: PlayerRoute? {
            guard case .player(let route) = self else { return nil }
            return route
        }
    }

    struct SessionSnapshot {
        var pending: PlayerRoute?
        var path: [SessionRoute]
    }

    @Published var pending: PlayerRoute?
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

    enum OpenMode {
        case push
        case replaceCurrent
    }

    var currentRoute: PlayerRoute? {
        path.reversed().compactMap(\.playerRoute).first ?? pending
    }

    var currentItem: FeedItemDTO? {
        currentRoute?.item
    }

    var playerPath: [PlayerRoute] {
        path.compactMap(\.playerRoute)
    }

    var snapshot: SessionSnapshot {
        SessionSnapshot(pending: pending, path: path)
    }

    func open(_ item: FeedItemDTO, mode: OpenMode = .push) {
        guard pending != nil else {
            path.removeAll()
            pending = PlayerRoute(item: item)
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

    func openUserSpace(mid: Int64) {
        guard pending != nil, mid > 0 else { return }
        path.append(.userSpace(UserSpaceRoute(mid: mid)))
    }

    func openDynamicDetail(_ item: DynamicItemDTO) {
        guard pending != nil else { return }
        path.append(.dynamicDetail(DynamicDetailRoute(item: item)))
    }

    func closeSession() {
        path.removeAll()
        pending = nil
    }

    func restore(_ snapshot: SessionSnapshot) {
        pending = snapshot.pending
        path = snapshot.path
    }

    func containsRoute(id: UUID) -> Bool {
        pending?.id == id || playerPath.contains { $0.id == id }
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
        default:
            return .handled
        }
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

    private func isCurrent(_ item: FeedItemDTO) -> Bool {
        guard let currentItem else { return false }
        return currentItem.aid == item.aid
            && currentItem.bvid == item.bvid
            && currentItem.cid == item.cid
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

        pending = pending?.replacingItem(item) ?? PlayerRoute(item: item)
    }
}
