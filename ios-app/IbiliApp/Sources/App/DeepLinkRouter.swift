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

    struct SessionSnapshot {
        var pending: PlayerRoute?
        var path: [PlayerRoute]
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
    @Published var path: [PlayerRoute] = []

    enum OpenMode {
        case push
        case replaceCurrent
    }

    var currentRoute: PlayerRoute? {
        path.last ?? pending
    }

    var currentItem: FeedItemDTO? {
        currentRoute?.item
    }

    var snapshot: SessionSnapshot {
        SessionSnapshot(pending: pending, path: path)
    }

    func open(_ item: FeedItemDTO, mode: OpenMode = .push) {
        guard !isCurrent(item) else { return }

        guard pending != nil else {
            path.removeAll()
            pending = PlayerRoute(item: item)
            return
        }

        switch mode {
        case .push:
            path.append(PlayerRoute(item: item))
        case .replaceCurrent:
            if path.isEmpty {
                pending = pending?.replacingItem(item) ?? PlayerRoute(item: item)
            } else {
                let index = path.index(before: path.endIndex)
                path[index] = path[index].replacingItem(item)
            }
        }
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
}
