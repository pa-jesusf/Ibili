import AVFoundation

/// Finishes on readiness, failure, source retirement, or caller cancellation.
/// The observer is retired on every exit, including a closed player session.
enum PlayerItemReadiness {
    private enum Event { case status(AVPlayerItem.Status), retired }

    @MainActor
    static func waitUntilReady(_ item: AVPlayerItem, player: AVPlayer) async throws {
        let (states, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = item.observe(\.status, options: [.initial, .new]) { item, change in
            continuation.yield(.status(change.newValue ?? item.status))
        }
        let ownership = player.observe(\.currentItem, options: [.initial, .new]) { player, _ in
            if player.currentItem !== item { continuation.yield(.retired) }
        }
        defer {
            observation.invalidate()
            ownership.invalidate()
            continuation.finish()
        }
        for await event in states {
            try Task.checkCancellation()
            guard player.currentItem === item else {
                throw NSError(domain: "Ibili.Player", code: 2, userInfo: [NSLocalizedDescriptionKey: "剧情播放源已更新，请重试"])
            }
            switch event {
            case .status(.readyToPlay): return
            case .status(.failed): throw item.error ?? NSError(domain: "Ibili.Player", code: 1, userInfo: [NSLocalizedDescriptionKey: "剧情片段加载失败，请重试"])
            default: break
            }
        }
        throw CancellationError()
    }
}
