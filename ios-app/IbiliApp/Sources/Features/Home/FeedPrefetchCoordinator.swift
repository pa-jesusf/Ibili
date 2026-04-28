import Foundation
import SwiftUI

/// Watches which feed cards are on screen and, after the scroll has
/// settled, kicks off Tier-1 prefetches for the topmost 1–2 entries.
///
/// We deliberately avoid Geometry/PreferenceKey scroll tracking because
/// `LazyVGrid` only materialises cells that are about to enter the
/// viewport. Treating `onAppear` as "near or in viewport" is therefore
/// a faithful proxy in practice while staying CPU-cheap.
@MainActor
final class FeedPrefetchCoordinator: ObservableObject {
    /// How long the visible set must remain unchanged before we treat
    /// it as a "settled" view and pay the network cost of prefetching.
    private let settleDelay: Duration = .milliseconds(500)
    /// The maximum number of leading visible cards we'll warm up. The
    /// product spec caps this at the top 1–2 fully visible cells.
    private let prefetchDepth = 2

    private var visibleAids: Set<Int64> = []
    /// Cards in their feed-order when they appeared; the lowest index
    /// is the topmost visible item.
    private var orderedItems: [FeedItemDTO] = []
    private var settleTask: Task<Void, Never>?

    var preferredQn: Int64 = 0

    func update(preferredQn: Int64) {
        self.preferredQn = preferredQn
    }

    func cardAppeared(_ item: FeedItemDTO, indexInFeed: Int, allItems: [FeedItemDTO]) {
        guard !visibleAids.contains(item.aid) else { return }
        visibleAids.insert(item.aid)
        orderedItems = allItems
        scheduleSettle()
    }

    func cardDisappeared(_ item: FeedItemDTO) {
        guard visibleAids.contains(item.aid) else { return }
        visibleAids.remove(item.aid)
        scheduleSettle()
    }

    /// Touch-Down warm-up. Bypasses the settle window because the user
    /// has explicitly committed to this card. Reclaims ~100–150 ms vs
    /// waiting for `.task` on the player screen to fire the playurl.
    func touchDown(_ item: FeedItemDTO) {
        PlayUrlPrefetcher.shared.prefetch(item: item,
                                          qn: max(preferredQn, 120))
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.settleDelay ?? .milliseconds(500))
            } catch { return }
            await MainActor.run { self?.fireSettlePrefetch() }
        }
    }

    private func fireSettlePrefetch() {
        guard !visibleAids.isEmpty else { return }
        let visible = visibleAids
        let top = orderedItems
            .filter { visible.contains($0.aid) }
            .prefix(prefetchDepth)
        for item in top {
            PlayUrlPrefetcher.shared.prefetch(item: item,
                                              qn: max(preferredQn, 120))
        }
        // Cancel any in-flight prefetches outside the new visible window
        // so the LRU never accumulates stale work.
        PlayUrlPrefetcher.shared.retain(visibleKeys: visible)
    }
}

/// Custom ButtonStyle that reports the moment the user's finger lands on
/// the card so we can fire the Touch-Down prefetch. `NavigationLink`
/// renders a Button internally; swapping `.buttonStyle(.plain)` for this
/// one preserves visual behaviour while exposing a press-down hook.
struct TouchDownReportingButtonStyle: ButtonStyle {
    let onPress: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { pressed in
                if pressed { onPress() }
            }
    }
}
