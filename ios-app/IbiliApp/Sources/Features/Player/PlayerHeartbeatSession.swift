import Foundation

struct PlayerHeartbeat: Equatable {
    let aid: Int64
    let bvid: String
    let cid: Int64
    let playedSeconds: Int64
}

/// One media item's reporting lifetime, independent of the route's mutable selection.
@MainActor
final class PlayerHeartbeatSession {
    private let aid: Int64
    private let bvid: String
    private let cid: Int64
    private let currentPosition: () -> Double?
    private let send: (PlayerHeartbeat) -> Void
    private var isActive = true
    private var lastReportedSecond: Int64?

    init(aid: Int64, bvid: String, cid: Int64,
         currentPosition: @escaping () -> Double?,
         send: @escaping (PlayerHeartbeat) -> Void) {
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        self.currentPosition = currentPosition
        self.send = send
    }

    func report(seconds: Double) {
        guard isActive, aid > 0, cid > 0, seconds.isFinite, seconds >= 0,
              let second = Int64(exactly: seconds.rounded(.towardZero)),
              second != lastReportedSecond else { return }
        lastReportedSecond = second
        send(PlayerHeartbeat(aid: aid, bvid: bvid, cid: cid, playedSeconds: second))
    }

    func finish() {
        guard isActive else { return }
        if let seconds = currentPosition() {
            report(seconds: seconds)
        }
        isActive = false
    }
}
