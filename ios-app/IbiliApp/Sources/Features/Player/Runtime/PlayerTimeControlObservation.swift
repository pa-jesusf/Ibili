import AVFoundation
import Foundation

/// Preserve synchronous AVKit command ordering on the main thread. Deferring
/// every KVO callback can turn a navigation pause into a user pause after pop.
@MainActor
final class PlayerTimeControlObservation {
    private var observation: NSKeyValueObservation?
    private let delivery: Delivery

    init(player: AVPlayer, onChange: @escaping @MainActor (AVPlayer, AVPlayer.TimeControlStatus) -> Void) {
        let delivery = Delivery(onChange: onChange)
        self.delivery = delivery
        // A newly attached transport starts paused; this is not a user pause.
        // Its owner applies the retained/autoplay intent after attachment.
        observation = player.observe(\.timeControlStatus) { [weak player] observed, _ in
            // Capture at emission, not after an actor hop. The Objective-C
            // enum isn't reliably bridged into change.newValue by KVO.
            let status = observed.timeControlStatus
            let item = observed.currentItem
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    delivery.receive(player, item: item, status: status)
                }
            } else {
                Task { @MainActor in
                    delivery.receive(player, item: item, status: status)
                }
            }
        }
    }

    func invalidate() {
        delivery.isActive = false
        observation?.invalidate()
        observation = nil
    }

    @MainActor
    private final class Delivery {
        var isActive = true
        let onChange: @MainActor (AVPlayer, AVPlayer.TimeControlStatus) -> Void

        init(onChange: @escaping @MainActor (AVPlayer, AVPlayer.TimeControlStatus) -> Void) {
            self.onChange = onChange
        }

        func receive(_ player: AVPlayer?, item: AVPlayerItem?, status: AVPlayer.TimeControlStatus) {
            guard isActive, let player, player.currentItem === item,
                  player.timeControlStatus == status else { return }
            onChange(player, status)
        }
    }
}
