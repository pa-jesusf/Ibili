import Foundation

enum NavigationIntent {
    case video(FeedItemDTO)
    case pgc(epID: Int64, seasonID: Int64)
    case user(mid: Int64)
    case dynamic(DynamicItemDTO)
    case live(roomID: Int64, title: String, cover: String, anchorName: String)
}

extension DeepLinkRouter {
    @MainActor
    func open(_ intent: NavigationIntent, prefersSplitRootSelection: Bool = false) {
        switch intent {
        case .video(let item):
            prefersSplitRootSelection ? select(item) : open(item)
        case .pgc(let epID, let seasonID):
            if epID > 0 {
                prefersSplitRootSelection ? selectPgc(epID: epID) : openPgc(epID: epID)
            } else if seasonID > 0 {
                prefersSplitRootSelection ? selectPgc(seasonID: seasonID) : openPgc(seasonID: seasonID)
            }
        case .user(let mid):
            prefersSplitRootSelection ? selectUserSpace(mid: mid) : openUserSpace(mid: mid)
        case .dynamic(let item):
            prefersSplitRootSelection ? selectDynamicDetail(item) : openDynamicDetail(item)
        case .live(let roomID, let title, let cover, let anchorName):
            if prefersSplitRootSelection {
                selectLive(roomID: roomID, title: title, cover: cover, anchorName: anchorName)
            } else {
                openLive(roomID: roomID, title: title, cover: cover, anchorName: anchorName)
            }
        }
    }
}
