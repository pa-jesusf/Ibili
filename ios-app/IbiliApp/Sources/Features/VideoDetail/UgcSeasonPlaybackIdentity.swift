import Foundation

/// A UGC season contains one entry per video submission. Its `cid` points to
/// one page (normally P1), so the submission identity must survive page changes.
struct UgcSeasonPlaybackIdentity: Hashable {
    let aid: Int64
    let bvid: String
    let cid: Int64

    func matches(_ episode: UgcSeasonEpisodeDTO) -> Bool {
        if aid > 0, episode.aid > 0, aid == episode.aid {
            return true
        }
        if !bvid.isEmpty, !episode.bvid.isEmpty,
           bvid.caseInsensitiveCompare(episode.bvid) == .orderedSame {
            return true
        }
        return cid > 0 && episode.cid == cid
    }
}

extension UgcSeasonDTO {
    func episode(matching identity: UgcSeasonPlaybackIdentity) -> UgcSeasonEpisodeDTO? {
        sections.lazy.flatMap(\.episodes).first(where: identity.matches)
    }

    func nextEpisode(after identity: UgcSeasonPlaybackIdentity) -> UgcSeasonEpisodeDTO? {
        let episodes = sections.flatMap(\.episodes)
        guard let currentIndex = episodes.firstIndex(where: identity.matches) else { return nil }
        let nextIndex = episodes.index(after: currentIndex)
        return episodes.indices.contains(nextIndex) ? episodes[nextIndex] : nil
    }
}
