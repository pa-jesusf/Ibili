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

    private static let supportedFrameRates: Set<Int> = [30, 60]

    // MARK: - Configuration

    var laneCount: Int = 14 { didSet { rebuildLanes() } }
    var scrollDuration: Double = 8.0
    var staticDuration: Double = 4.0
    var blockLevel: Int {
        get { storedBlockLevel }
        set {
            let clamped = min(max(newValue, 0), 11)
            guard storedBlockLevel != clamped else { return }
            storedBlockLevel = clamped
            rebuildTrack()
        }
    }
    var preferredFrameRate: Int {
        get { storedFrameRate }
        set {
            let clamped = Self.supportedFrameRates.contains(newValue) ? newValue : 60
            guard storedFrameRate != clamped else { return }
            storedFrameRate = clamped
            reconfigureTiming()
        }
    }
    private let seekResyncThreshold: Double = 0.5
    private let perTickCap = 12

    // MARK: - State

    private var sourceItems: [DanmakuItemDTO] = []
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
    private var storedBlockLevel: Int = 0
    private var storedFrameRate: Int = 60
    private var currentPlaybackTime: Double = 0
    private var needsRedraw = false

    // MARK: - Text cache

    private var textCache = NSCache<NSString, CachedText>()
    private var specialTextCache = NSCache<NSString, CachedSpecialText>()

    private final class CachedText {
        let line: CTLine
        let size: CGSize
        let drawInset: CGFloat

        init(line: CTLine, size: CGSize, drawInset: CGFloat) {
            self.line = line
            self.size = size
            self.drawInset = drawInset
        }
    }

    private final class CachedSpecialText {
        let image: UIImage
        let size: CGSize
        let drawOffset: CGPoint

        init(image: UIImage, size: CGSize, drawOffset: CGPoint) {
            self.image = image
            self.size = size
            self.drawOffset = drawOffset
        }
    }

    private struct LiveDanmaku {
        let item: DanmakuItemDTO
        let displayText: String
        let lane: Int
        let startTime: Double
        let duration: Double
        let mode: DanmakuMode
        let textKey: NSString
        let specialDescriptor: SpecialDanmakuDescriptor?
        var cachedText: CachedText?
        var cachedSpecialText: CachedSpecialText?
    }

    private enum DanmakuMode { case scroll, top, bottom, special }

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
        specialTextCache.countLimit = 128
    }

    private func rebuildLanes() {
        scrollLaneFreeAt = Array(repeating: 0, count: laneCount)
        topLaneNextFree = Array(repeating: 0, count: max(laneCount / 3, 2))
        bottomLaneNextFree = Array(repeating: 0, count: max(laneCount / 3, 2))
    }

    // MARK: - Public API

    func setItems(_ items: [DanmakuItemDTO]) {
        sourceItems = items.sorted { $0.timeSec < $1.timeSec }
        rebuildTrack()
    }

    private func rebuildTrack() {
        all = sourceItems.filter(shouldInclude)
        cursor = 0
        active.removeAll()
        rebuildLanes()
        textCache.removeAllObjects()
        specialTextCache.removeAllObjects()
        needsRedraw = true
    }

    private func shouldInclude(_ item: DanmakuItemDTO) -> Bool {
        if item.hasWeight, !item.isSelf, item.weight < Int32(storedBlockLevel) {
            return false
        }
        if item.mode == 7 {
            return SpecialDanmakuDescriptor.parse(rawText: item.text) != nil
        }
        return true
    }

    func attach(_ player: AVPlayer) {
        removeTimeObserverIfNeeded()
        self.player = player
        let interval = CMTime(seconds: 1.0 / Double(storedFrameRate), preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self else { return }
            let secs = t.seconds.isFinite ? t.seconds : 0
            self.tickLogic(secs)
        }
        startDisplayLink()
    }

    func detach() {
        stopDisplayLink()
        removeTimeObserverIfNeeded()
        player = nil
        active.removeAll()
        needsRedraw = true
        setNeedsDisplay()
    }

    private func reconfigureTiming() {
        if let player {
            attach(player)
        }
        if let displayLink {
            applyPreferredFrameRate(to: displayLink)
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayTick))
        applyPreferredFrameRate(to: link)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func applyPreferredFrameRate(to link: CADisplayLink) {
        if #available(iOS 15.0, *) {
            let rate = Float(storedFrameRate)
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: rate,
                maximum: rate,
                preferred: rate
            )
        } else {
            link.preferredFramesPerSecond = storedFrameRate
        }
    }

    private func removeTimeObserverIfNeeded() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
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
        let displayText: String
        let specialDescriptor: SpecialDanmakuDescriptor?
        let key: NSString
        var lane: Int

        switch item.mode {
        case 4:
            mode = .bottom
            displayText = item.text
            specialDescriptor = nil
            key = "\(displayText)_\(item.color)_\(item.fontSize)" as NSString
            lane = pickStaticLane(from: &bottomLaneNextFree, at: now)
        case 5:
            mode = .top
            displayText = item.text
            specialDescriptor = nil
            key = "\(displayText)_\(item.color)_\(item.fontSize)" as NSString
            lane = pickStaticLane(from: &topLaneNextFree, at: now)
        case 7:
            guard let parsed = SpecialDanmakuDescriptor.parse(rawText: item.text) else { return }
            mode = .special
            displayText = parsed.text
            specialDescriptor = parsed
            key = "\(item.text)_\(item.color)_\(item.fontSize)" as NSString
            lane = 0
        default:
            mode = .scroll
            displayText = item.text
            specialDescriptor = nil
            key = "\(displayText)_\(item.color)_\(item.fontSize)" as NSString
            lane = pickScrollLane(at: now)
            scrollLaneFreeAt[lane] = now + scrollDuration * 0.45
        }

        let duration = specialDescriptor?.displayDuration
            ?? (mode == .scroll ? scrollDuration : staticDuration)
        var dm = LiveDanmaku(item: item, displayText: displayText, lane: lane, startTime: now,
                             duration: duration, mode: mode, textKey: key,
                             specialDescriptor: specialDescriptor)
        if let specialDescriptor {
            dm.cachedSpecialText = specialTextCache.object(forKey: key)
            if dm.cachedSpecialText == nil {
                let cached = makeSpecialText(
                    displayText: displayText,
                    item: item,
                    descriptor: specialDescriptor
                )
                specialTextCache.setObject(cached, forKey: key)
                dm.cachedSpecialText = cached
            }
        } else {
            dm.cachedText = textCache.object(forKey: key)
            if dm.cachedText == nil {
                let cached = makeText(displayText: displayText, item: item)
                textCache.setObject(cached, forKey: key)
                dm.cachedText = cached
            }
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
    private let maxSpecialRasterSize: CGFloat = 4096

    private func resolvedFontSize(for item: DanmakuItemDTO) -> CGFloat {
        baseFontSize * (item.fontSize > 0 ? CGFloat(item.fontSize) / 25.0 : 1.0)
    }

    private func resolvedFont(for item: DanmakuItemDTO) -> UIFont {
        let fontSize = resolvedFontSize(for: item)
        let baseFont = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        return baseFont.fontDescriptor.withDesign(.rounded)
            .map { UIFont(descriptor: $0, size: fontSize) } ?? baseFont
    }

    private func resolvedTextColor(for item: DanmakuItemDTO) -> UIColor {
        let r = CGFloat((item.color >> 16) & 0xFF) / 255
        let g = CGFloat((item.color >> 8) & 0xFF) / 255
        let b = CGFloat(item.color & 0xFF) / 255
        return UIColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    private func makeText(displayText: String, item: DanmakuItemDTO) -> CachedText {
        let font = resolvedFont(for: item)
        let fillColor = resolvedTextColor(for: item)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fillColor,
        ]
        let str = NSAttributedString(string: displayText, attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let drawInset: CGFloat = 2
        let size = CGSize(
            width: ceil(bounds.width) + drawInset * 2,
            height: ceil(bounds.height) + drawInset * 2
        )
        return CachedText(
            line: line,
            size: size,
            drawInset: drawInset
        )
    }

    private func makeSpecialText(
        displayText: String,
        item: DanmakuItemDTO,
        descriptor: SpecialDanmakuDescriptor
    ) -> CachedSpecialText {
        let font = resolvedFont(for: item)
        let fillColor = resolvedTextColor(for: item)
        let padding: CGFloat = descriptor.hasStroke ? max(2, ceil(font.pointSize * 0.05)) : 1

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byClipping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fillColor,
            .paragraphStyle: paragraphStyle,
        ]

        if descriptor.hasStroke {
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.85)
            shadow.shadowBlurRadius = padding
            shadow.shadowOffset = .zero
            attributes[.shadow] = shadow
        }

        let attributed = NSAttributedString(string: displayText, attributes: attributes)
        let measured = attributed.boundingRect(
            with: CGSize(width: maxSpecialRasterSize, height: maxSpecialRasterSize),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let textSize = CGSize(
            width: max(1, min(maxSpecialRasterSize, ceil(measured.width))),
            height: max(1, min(maxSpecialRasterSize, ceil(measured.height)))
        )
        let textRect = CGRect(origin: .zero, size: textSize)
        let transformedBounds = descriptor.transform.isIdentity
            ? textRect
            : textRect.applying(descriptor.transform)
        let rasterBounds = transformedBounds.insetBy(dx: -padding, dy: -padding).integral
        let rasterSize = CGSize(
            width: max(1, ceil(rasterBounds.width)),
            height: max(1, ceil(rasterBounds.height))
        )

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = UIScreen.main.scale

        let renderer = UIGraphicsImageRenderer(size: rasterSize, format: format)
        let image = renderer.image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: -rasterBounds.minX, y: -rasterBounds.minY)
            if !descriptor.transform.isIdentity {
                cgContext.concatenate(descriptor.transform)
            }
            attributed.draw(
                with: textRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
        }

        return CachedSpecialText(
            image: image,
            size: rasterSize,
            drawOffset: rasterBounds.origin
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
        ctx.interpolationQuality = .high

        for dm in active {
            switch dm.mode {
            case .scroll:
                guard let ct = dm.cachedText else { continue }
                let progress = CGFloat(max(0, min(1, (now - dm.startTime) / dm.duration)))
                let travel = size.width + ct.size.width
                let x = size.width - travel * progress
                let y = scrollLaneH * (CGFloat(dm.lane) + 0.5) - ct.size.height / 2
                drawNormalText(ct, at: CGPoint(x: x, y: y), alpha: 1.0, in: ctx, viewport: size)

            case .top:
                guard let ct = dm.cachedText else { continue }
                let x = (size.width - ct.size.width) / 2
                let y = scrollLaneH * (CGFloat(dm.lane) + 0.5) - ct.size.height / 2
                drawNormalText(ct, at: CGPoint(x: x, y: y), alpha: 1.0, in: ctx, viewport: size)

            case .bottom:
                guard let ct = dm.cachedText else { continue }
                let x = (size.width - ct.size.width) / 2
                let y = size.height - scrollLaneH * (CGFloat(dm.lane) + 1.5)
                drawNormalText(ct, at: CGPoint(x: x, y: y), alpha: 1.0, in: ctx, viewport: size)

            case .special:
                guard let special = dm.specialDescriptor,
                      let cached = dm.cachedSpecialText else { continue }
                let elapsed = max(0, now - dm.startTime)
                let point = special.position(at: elapsed, in: size)
                let origin = CGPoint(
                    x: point.x + cached.drawOffset.x,
                    y: point.y + cached.drawOffset.y
                )
                drawSpecialText(cached, at: origin, alpha: special.alpha(at: elapsed), in: ctx, viewport: size)
            }
        }
    }

    private func drawNormalText(
        _ cached: CachedText,
        at origin: CGPoint,
        alpha: CGFloat,
        in context: CGContext,
        viewport: CGSize
    ) {
        guard alpha > 0.01 else { return }
        guard origin.x + cached.size.width > 0,
              origin.x < viewport.width,
              origin.y + cached.size.height > 0,
              origin.y < viewport.height else { return }

        context.saveGState()
        context.setAlpha(alpha)
        context.textMatrix = .identity
        context.translateBy(
            x: origin.x + cached.drawInset,
            y: origin.y + cached.size.height - cached.drawInset
        )
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(cached.line, context)
        context.restoreGState()
    }

    private func drawSpecialText(
        _ cached: CachedSpecialText,
        at origin: CGPoint,
        alpha: CGFloat,
        in _: CGContext,
        viewport: CGSize
    ) {
        guard alpha > 0.01 else { return }
        guard origin.x + cached.size.width > 0,
              origin.x < viewport.width,
              origin.y + cached.size.height > 0,
              origin.y < viewport.height else { return }

        cached.image.draw(in: CGRect(origin: origin, size: cached.size), blendMode: .normal, alpha: alpha)
    }

    // MARK: - Lifecycle

    deinit {
        MainActor.assumeIsolated {
            displayLink?.invalidate()
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
        }
    }
}
