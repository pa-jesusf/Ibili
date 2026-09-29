import Foundation

enum PlayerResumePolicy {
    static func isMediaReplacement(from previous: FeedItemDTO?, to next: FeedItemDTO) -> Bool {
        guard let previous else { return false }
        if previous.cid != next.cid { return true }
        if previous.aid > 0, next.aid > 0, previous.aid != next.aid { return true }
        if !previous.bvid.isEmpty, !next.bvid.isEmpty, previous.bvid != next.bvid { return true }
        if previous.epID != next.epID || previous.seasonID != next.seasonID || previous.isPGC != next.isPGC {
            return true
        }
        return false
    }

    static func isPartSwitch(from previous: FeedItemDTO?, to next: FeedItemDTO) -> Bool {
        guard let previous,
              previous.aid == next.aid,
              previous.cid != next.cid else { return false }
        if !previous.bvid.isEmpty, !next.bvid.isEmpty {
            return previous.bvid == next.bvid
        }
        return previous.aid > 0
    }

    static func initialResumeMilliseconds(
        previous: FeedItemDTO?,
        next: FeedItemDTO,
        explicitMilliseconds: Int64?,
        serverMilliseconds: Int64,
        serverCid: Int64
    ) -> Int64 {
        if let explicitMilliseconds {
            return max(0, explicitMilliseconds)
        }
        if isMediaReplacement(from: previous, to: next) {
            return serverCid == next.cid ? max(0, serverMilliseconds) : 0
        }
        if serverCid == 0 || serverCid == next.cid {
            return max(0, serverMilliseconds)
        }
        return 0
    }

    static func targetSeconds(milliseconds: Int64, duration: Double, isExplicit: Bool) -> Double {
        let seconds = Double(max(0, milliseconds)) / 1000
        guard duration.isFinite, duration > 0 else { return seconds }
        // Only inferred account history treats the last three seconds as
        // completed. A timestamp explicitly selected by the user stays exact.
        return seconds < (isExplicit ? duration : duration - 3) ? seconds : 0
    }
}
