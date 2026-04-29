import UIKit
import AVFoundation
import Combine

// MARK: - Canvas-based danmaku renderer

/// High-performance danmaku renderer using Core Graphics canvas drawing.
/// Replaces the SwiftUI ForEach+Text approach with direct bitmap rendering
/// via CADisplayLink, following the same architectural pattern as the
/// upstream `canvas_danmaku` Flutter library.
///
/// Key optimizations:
/// - Single `UIView` with `CADisplayLink` instead of 100s of SwiftUI Text views
/// - Pre-rasterized `NSAttributedString` with `CTLine` cached per danmaku
/// - Stroke-based outline (1 draw call) instead of 8 offset copies
/// - Dirty-rect tracking to minimize overdraw
/// - Lane-based collision avoidance with separate pools for scroll/top/bottom
@MainActor
final class DanmakuCanvasView: UIView {

    // MARK: - Configuration

    var laneCount: Int = 14 { didSet { rebuildLanes() } }
    var scrollDuration: Double = 8.0
    var staticDuration: Double = 4.0
    private let seekResyncThreshold: Double = 0.5
    private let perTickCap = 12

    // MARK: - State

    private var all: [DanmakuItemDTO] = []
    private var active: [LiveDanmaku] = []
    private var cursor: Int = 0
    private var lastTime: Double = 0

    private var scrollLaneFreeAt: [Double] = []
    private var topLaneNextFree: [Double] = []
    private var bottomLaneNextFree: [Double] = []

    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var displayLink: CADisplayLink?
    private var currentPlaybackTime: Double = 0
    private var needsRedraw = false

    // MARK: - Text cache

    private var textCache = NSCache<NSString, CachedText>()

    private final class CachedText {
        let line: CTLine
        let size: CGSize
        let fillColor: UIColor
        let outlineWidth: CGFloat
        let drawInset: CGFloat

        init(line: CTLine, size: CGSize, fillColor: UIColor, outlineWidth: CGFloat, drawInset: CGFloat) {
            self.line = line
            self.size = size
            self.fillColor = fillColor
            self.outlineWidth = outlineWidth
            self.drawInset = drawInset
        }
    }

    private struct LiveDanmaku {
        let item: DanmakuItemDTO
        let lane: Int
        let startTime: Double
        let duration: Double
        let mode: DanmakuMode
        let textKey: NSString
        var cachedText: CachedText?
    }

    private enum DanmakuMode { case scroll, top, bottom }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clearsContextBeforeDrawing = true
        contentMode = .redraw
        rebuildLanes()

        textCache.countLimit = 512
    }

    private func rebuildLanes() {
        scrollLaneFreeAt = Array(repeating: 0, count: laneCount)
        topLaneNextFree = Array(repeating: 0, count: max(laneCount / 3, 2))
        bottomLaneNextFree = Array(repeating: 0, count: max(laneCount / 3, 2))
    }

    // MARK: - Public API

    func setItems(_ items: [DanmakuItemDTO]) {
        all = items.sorted { $0.timeSec < $1.timeSec }
        cursor = 0
        active.removeAll()
        rebuildLanes()
        textCache.removeAllObjects()
        needsRedraw = true
    }

    func attach(_ player: AVPlayer) {
        detach()
        self.player = player
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self else { return }
            let secs = t.seconds.isFinite ? t.seconds : 0
            self.tickLogic(secs)
        }
        startDisplayLink()
    }

    func detach() {
        stopDisplayLink()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player = nil
        active.removeAll()
        needsRedraw = true
        setNeedsDisplay()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayTick))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30, maximum: 120, preferred: 60
            )
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        if needsRedraw || !active.isEmpty {
            setNeedsDisplay()
            needsRedraw = false
        }
    }

    // MARK: - Logic tick (driven by player time observer at 30Hz)

    private func tickLogic(_ now: Double) {
        if abs(now - lastTime) > seekResyncThreshold {
            active.removeAll()
            rebuildLanes()
            cursor = lowerBound(of: Float(now))
        }
        lastTime = now
        currentPlaybackTime = now

        active.removeAll { now > $0.startTime + $0.duration }

        var added = 0
        while cursor < all.count, Double(all[cursor].timeSec) <= now + 0.05 {
            schedule(all[cursor], at: now)
            cursor += 1
            added += 1
            if added > perTickCap { break }
        }

        needsRedraw = true
    }

    private func schedule(_ item: DanmakuItemDTO, at now: Double) {
        let mode: DanmakuMode
        var lane: Int

        switch item.mode {
        case 4:
            mode = .bottom
            lane = pickStaticLane(from: &bottomLaneNextFree, at: now)
        case 5:
            mode = .top
            lane = pickStaticLane(from: &topLaneNextFree, at: now)
        default:
            mode = .scroll
            lane = pickScrollLane(at: now)
            scrollLaneFreeAt[lane] = now + scrollDuration * 0.45
        }

        let duration = mode == .scroll ? scrollDuration : staticDuration
        let key = "\(item.text)_\(item.color)_\(item.fontSize)" as NSString
        var dm = LiveDanmaku(item: item, lane: lane, startTime: now,
                             duration: duration, mode: mode, textKey: key)
        dm.cachedText = textCache.object(forKey: key)
        if dm.cachedText == nil {
            let ct = makeText(item)
            textCache.setObject(ct, forKey: key)
            dm.cachedText = ct
        }
        active.append(dm)
    }

    private func pickScrollLane(at now: Double) -> Int {
        if let idx = scrollLaneFreeAt.firstIndex(where: { $0 <= now }) { return idx }
        return Int.random(in: 0..<scrollLaneFreeAt.count)
    }

    private func pickStaticLane(from pool: inout [Double], at now: Double) -> Int {
        if let idx = pool.firstIndex(where: { $0 <= now }) {
            pool[idx] = now + staticDuration
            return idx
        }
        let idx = Int.random(in: 0..<pool.count)
        pool[idx] = now + staticDuration
        return idx
    }

    private func lowerBound(of t: Float) -> Int {
        var lo = 0, hi = all.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if all[mid].timeSec < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: - Text rendering

    private let baseFontSize: CGFloat = 18

    private func makeText(_ item: DanmakuItemDTO) -> CachedText {
        let fontSize = baseFontSize * (item.fontSize > 0 ? CGFloat(item.fontSize) / 25.0 : 1.0)
        let baseFont = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let font = baseFont.fontDescriptor.withDesign(.rounded)
            .map { UIFont(descriptor: $0, size: fontSize) } ?? baseFont

        let r = CGFloat((item.color >> 16) & 0xFF) / 255
        let g = CGFloat((item.color >> 8) & 0xFF) / 255
        let b = CGFloat(item.color & 0xFF) / 255
        let fillColor = UIColor(red: r, green: g, blue: b, alpha: 1.0)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
        ]
        let str = NSAttributedString(string: item.text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let outlineWidth = max(1.25, fontSize * 0.055)
        let drawInset = ceil(outlineWidth) + 2
        let size = CGSize(
            width: ceil(bounds.width) + drawInset * 2,
            height: ceil(bounds.height) + drawInset * 2
        )
        return CachedText(
            line: line,
            size: size,
            fillColor: fillColor,
            outlineWidth: outlineWidth,
            drawInset: drawInset
        )
    }

    // MARK: - Draw

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let now = currentPlaybackTime
        let scrollLaneH = max(20, size.height / CGFloat(laneCount + 1))

        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)

        for dm in active {
            guard let ct = dm.cachedText else { continue }

            let x: CGFloat
            let y: CGFloat

            switch dm.mode {
            case .scroll:
                let progress = CGFloat(max(0, min(1, (now - dm.startTime) / dm.duration)))
                let travel = size.width + ct.size.width
                x = size.width - travel * progress
                y = scrollLaneH * (CGFloat(dm.lane) + 0.5) - ct.size.height / 2

            case .top:
                x = (size.width - ct.size.width) / 2
                y = scrollLaneH * (CGFloat(dm.lane) + 0.5) - ct.size.height / 2

            case .bottom:
                x = (size.width - ct.size.width) / 2
                y = size.height - scrollLaneH * (CGFloat(dm.lane) + 1.5)
            }

            guard x + ct.size.width > 0, x < size.width else { continue }

            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: x + ct.drawInset, y: y + ct.size.height - ct.drawInset)
            ctx.scaleBy(x: 1, y: -1)

            ctx.setLineJoin(.round)
            ctx.setTextDrawingMode(.stroke)
            ctx.setLineWidth(ct.outlineWidth)
            ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.92).cgColor)
            CTLineDraw(ct.line, ctx)

            ctx.setTextDrawingMode(.fill)
            ctx.setFillColor(ct.fillColor.cgColor)
            CTLineDraw(ct.line, ctx)
            ctx.restoreGState()
        }
    }

    // MARK: - Lifecycle

    deinit {
        displayLink?.invalidate()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
    }
}
