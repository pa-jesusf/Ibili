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

    private var visibleItems: [FeedItemDTO] = []
    private var settleTask: Task<Void, Never>?

    var preferredQn: Int64 = 0
    var preferredAudioQn: Int64 = 0
    private var cdnSelection: String = MediaCDNService.auto.rawValue

    func update(preferredQn: Int64, preferredAudioQn: Int64, cdnSelection: String) {
        self.preferredQn = preferredQn
        self.preferredAudioQn = preferredAudioQn
        self.cdnSelection = cdnSelection
    }

    func visibleItemsChanged(_ items: [FeedItemDTO]) {
        let newIDs = items.map(\.aid)
        guard newIDs != visibleItems.map(\.aid) else { return }
        visibleItems = items
        scheduleSettle()
    }

    func clearVisibleItems() {
        visibleItems.removeAll()
        PlayUrlPrefetcher.shared.retain(visibleKeys: [])
    }

    /// Touch-Down warm-up. Bypasses the settle window because the user
    /// has explicitly committed to this card. Reclaims ~100–150 ms vs
    /// waiting for `.task` on the player screen to fire the playurl.
    func touchDown(_ item: FeedItemDTO) {
        PlayUrlPrefetcher.shared.prefetch(item: item,
                                          qn: max(preferredQn, 120),
                                          audioQn: preferredAudioQn,
                                          cdn: cdnSelection)
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
        guard !visibleItems.isEmpty else { return }
        let visible = Set(visibleItems.map(\.aid))
        let top = visibleItems.prefix(prefetchDepth)
        for item in top {
            PlayUrlPrefetcher.shared.prefetch(item: item,
                                              qn: max(preferredQn, 120),
                                              audioQn: preferredAudioQn,
                                              cdn: cdnSelection)
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
