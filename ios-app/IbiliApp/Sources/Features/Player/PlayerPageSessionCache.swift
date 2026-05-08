import Foundation

private struct PlayerPagePlayURLKey: Hashable {
    let qn: Int64
    let audioQn: Int64
    let variant: String
}

@MainActor
final class PlayerPageSessionCache {
    let detailViewModel = VideoDetailViewModel()
    let commentListViewModel = CommentListViewModel()
    let interactionService = VideoInteractionService()

    private var playURLs: [PlayerPagePlayURLKey: PlayUrlDTO] = [:]
    private var danmakuTracks: [Int64: [DanmakuItemDTO]] = [:]

    func clearMediaData() {
        playURLs.removeAll()
        danmakuTracks.removeAll()
        interactionService.resetForNextItem()
    }

    func storePlayURL(_ info: PlayUrlDTO, variant: String) {
        let key = PlayerPagePlayURLKey(qn: info.quality, audioQn: info.audioQuality, variant: variant)
        playURLs[key] = info
    }

    func playURL(qn: Int64, audioQn: Int64, variant: String) -> PlayUrlDTO? {
        let exactKey = PlayerPagePlayURLKey(qn: qn, audioQn: audioQn, variant: variant)
        if let exact = playURLs[exactKey] {
            return exact
        }
        return playURLs.first(where: { $0.key.qn == qn && $0.key.variant == variant })?.value
    }

    func removePlayURL(qn: Int64, audioQn: Int64, variant: String) {
        let exactKey = PlayerPagePlayURLKey(qn: qn, audioQn: audioQn, variant: variant)
        playURLs.removeValue(forKey: exactKey)
        if audioQn == 0 {
            playURLs.keys
                .filter { $0.qn == qn && $0.variant == variant }
                .forEach { playURLs.removeValue(forKey: $0) }
        }
    }

    func storeDanmaku(_ items: [DanmakuItemDTO], for cid: Int64) {
        danmakuTracks[cid] = items
    }

    func danmaku(for cid: Int64) -> [DanmakuItemDTO]? {
        danmakuTracks[cid]
    }
}
