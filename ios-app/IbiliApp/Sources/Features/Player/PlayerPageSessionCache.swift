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
    private var danmakuSegments: [Int64: [Int64: [DanmakuItemDTO]]] = [:]

    func clearMediaData() {
        playURLs.removeAll()
        danmakuTracks.removeAll()
        danmakuSegments.removeAll()
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
        guard audioQn == 0 else { return nil }
        return playURLs
            .filter { $0.key.qn == qn && $0.key.variant == variant }
            .max { audioQualityRank($0.key.audioQn) < audioQualityRank($1.key.audioQn) }?
            .value
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

    private func audioQualityRank(_ qn: Int64) -> Int {
        switch qn {
        case 100010: return 800
        case 100009: return 700
        case 100008: return 600
        case 30251: return 500
        case 30250, 30255: return 400
        case 30280: return 300
        case 30232: return 200
        case 30216: return 100
        default: return 0
        }
    }

    func storeDanmaku(_ items: [DanmakuItemDTO], for cid: Int64) {
        danmakuTracks[cid] = items
    }

    func danmaku(for cid: Int64) -> [DanmakuItemDTO]? {
        danmakuTracks[cid]
    }

    func storeDanmakuSegment(_ items: [DanmakuItemDTO], cid: Int64, segmentIndex: Int64) {
        var segments = danmakuSegments[cid] ?? [:]
        segments[segmentIndex] = items
        danmakuSegments[cid] = segments
    }

    func danmakuSegment(cid: Int64, segmentIndex: Int64) -> [DanmakuItemDTO]? {
        danmakuSegments[cid]?[segmentIndex]
    }
}
