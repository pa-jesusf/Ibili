import SwiftUI
import AVFoundation
import Combine

/// Lightweight scrolling-danmaku controller.
///
/// IMPORTANT: This is **not** an `ObservableObject`. The renderer subscribes to
/// the `publisher` for active-comment updates. If we made the controller an
/// `ObservableObject` and stored it via `@StateObject` in `PlayerView`, every
/// 30 Hz tick would re-render the entire player view, tear down `Menu` popovers
/// mid-tap, and fight `AVPlayerViewController`'s fullscreen transition. Keeping
/// updates scoped to the leaf overlay view via Combine fixes all of that.
@MainActor
final class DanmakuController {
    struct Snapshot {
        let playbackTime: Double
        let active: [Active]
    }

    /// All comments, sorted by `timeSec`.
    private var all: [DanmakuItemDTO] = []
    /// Active comments currently animating on screen.
    private var active: [Active] = []
    /// Updates emitted at every player time-observer tick.
    let publisher = CurrentValueSubject<Snapshot, Never>(Snapshot(playbackTime: 0, active: []))

    private weak var player: AVPlayer?
    private var observer: Any?
    private var lastTime: Double = 0
    private var cursor: Int = 0

    private let laneCount = 12
    private let scrollDuration: Double = 8
    private let staticDuration: Double = 4
    private var laneFreeAt: [Double] = []

    struct Active: Identifiable, Equatable {
        let id = UUID()
        let item: DanmakuItemDTO
        let lane: Int
        let startTime: Double
        let duration: Double
        let mode: Mode
        enum Mode { case scroll, top, bottom }
        static func == (a: Active, b: Active) -> Bool { a.id == b.id }
    }

    func setItems(_ items: [DanmakuItemDTO]) {
        self.all = items.sorted { $0.timeSec < $1.timeSec }
        self.cursor = 0
        self.active.removeAll()
        self.laneFreeAt = Array(repeating: 0, count: laneCount)
        publisher.send(Snapshot(playbackTime: 0, active: []))
    }

    func attach(_ player: AVPlayer) {
        detach()
        self.player = player
        let interval = CMTime(seconds: 1.0/30.0, preferredTimescale: 600)
        observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            let secs = t.seconds.isFinite ? t.seconds : 0
            Task { @MainActor [weak self] in self?.tick(secs) }
        }
    }

    func detach() {
        if let observer, let player {
            player.removeTimeObserver(observer)
        }
        observer = nil
        player = nil
        active.removeAll()
        publisher.send(Snapshot(playbackTime: lastTime, active: []))
    }

    deinit {
        if let observer, let player {
            player.removeTimeObserver(observer)
        }
    }

    private func tick(_ now: Double) {
        // Seek backwards: rewind cursor + drop active.
        if now + 0.5 < lastTime {
            active.removeAll()
            laneFreeAt = Array(repeating: 0, count: laneCount)
            cursor = lowerBound(of: Float(now))
        }
        lastTime = now

        // Drop expired.
        active.removeAll { now > $0.startTime + $0.duration }

        // Schedule new ones up to `now + 0.05` lookahead.
        var added = 0
        while cursor < all.count, Double(all[cursor].timeSec) <= now + 0.05 {
            schedule(all[cursor], at: now)
            cursor += 1
            added += 1
            if added > 8 { break } // per-tick cap
        }

        publisher.send(Snapshot(playbackTime: now, active: active))
    }

    private func schedule(_ item: DanmakuItemDTO, at now: Double) {
        switch item.mode {
        case 4:
            active.append(Active(item: item, lane: 0, startTime: now, duration: staticDuration, mode: .bottom))
        case 5:
            active.append(Active(item: item, lane: 0, startTime: now, duration: staticDuration, mode: .top))
        default:
            let lane = pickLane(at: now)
            laneFreeAt[lane] = now + scrollDuration * 0.55
            active.append(Active(item: item, lane: lane, startTime: now, duration: scrollDuration, mode: .scroll))
        }
    }

    private func pickLane(at now: Double) -> Int {
        if let idx = laneFreeAt.firstIndex(where: { $0 <= now }) { return idx }
        return Int.random(in: 0..<laneCount)
    }

    private func lowerBound(of t: Float) -> Int {
        var lo = 0, hi = all.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if all[mid].timeSec < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// SwiftUI overlay rendering active danmaku. Subscribes to the controller's
/// `publisher`, so re-renders are scoped to this view only.
struct DanmakuOverlay: View {
    let controller: DanmakuController
    let opacity: Double
    @State private var snapshot = DanmakuController.Snapshot(playbackTime: 0, active: [])

    var body: some View {
        GeometryReader { geo in
            let laneHeight = max(20, geo.size.height / 14)
            ZStack(alignment: .topLeading) {
                ForEach(snapshot.active) { a in
                    DanmakuLabel(item: a.item)
                        .modifier(DanmakuPosition(
                            active: a,
                            playbackTime: snapshot.playbackTime,
                            size: geo.size,
                            laneHeight: laneHeight
                        ))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .allowsHitTesting(false)
            .opacity(opacity)
        }
        .onReceive(controller.publisher) { snapshot = $0 }
    }
}

private struct DanmakuLabel: View {
    let item: DanmakuItemDTO
    var body: some View {
        Text(item.text)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(Color(red: Double((item.color >> 16) & 0xFF) / 255,
                                   green: Double((item.color >> 8) & 0xFF) / 255,
                                   blue: Double(item.color & 0xFF) / 255))
            .shadow(color: .black.opacity(0.7), radius: 1, x: 1, y: 1)
            .lineLimit(1)
            .fixedSize()
    }
}

private struct DanmakuPosition: ViewModifier {
    let active: DanmakuController.Active
    let playbackTime: Double
    let size: CGSize
    let laneHeight: CGFloat

    func body(content: Content) -> some View {
        switch active.mode {
        case .scroll:
            let progress = max(0, min(1, (playbackTime - active.startTime) / active.duration))
            let travel = size.width * 2.0
            let x = size.width * 1.5 - travel * progress
            content
                .position(x: x, y: laneHeight * (CGFloat(active.lane) + 0.5))
        case .top:
            content
                .position(x: size.width / 2, y: laneHeight * 0.5)
        case .bottom:
            content
                .position(x: size.width / 2, y: size.height - laneHeight * 0.5)
        }
    }
}
