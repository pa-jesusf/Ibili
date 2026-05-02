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
    /// Black halo width for normal (non mode-7) danmaku. The slider
    /// drives how many font-weight tiers we bump when laying out the
    /// underlay glyph run; a heavier-weight black draw underneath the
    /// foreground text yields a halo that scales with the chosen
    /// font size *and* renders correctly on CJK glyphs (Core Text's
    /// `kCTStrokeWidthAttribute` would otherwise paint the strokes
    /// inside Chinese characters' interior structure). Total cost
    /// is two `CTLineDraw` calls per bullet, both pre-cached.
    /// Setter invalidates the text cache so the change takes effect
    /// on the next bullet, without having to tear the canvas down.
    var normalStrokeWidth: CGFloat {
        get { storedNormalStrokeWidth }
        set {
            let clamped = max(0, min(newValue, 6))
            guard storedNormalStrokeWidth != clamped else { return }
            storedNormalStrokeWidth = clamped
            textCache.removeAllObjects()
            needsRedraw = true
        }
    }
    /// 1...9, mirrors the SettingsView slider; 6 ≈ semibold.
    var normalFontWeight: Int {
        get { storedNormalFontWeight }
        set {
            let clamped = max(1, min(newValue, 9))
            guard storedNormalFontWeight != clamped else { return }
            storedNormalFontWeight = clamped
            textCache.removeAllObjects()
            needsRedraw = true
        }
    }
    /// Multiplier applied on top of the per-bullet `fontSize`.
    var normalFontScale: CGFloat {
        get { storedNormalFontScale }
        set {
            let clamped = max(0.6, min(newValue, 1.6))
            guard storedNormalFontScale != clamped else { return }
            storedNormalFontScale = clamped
            textCache.removeAllObjects()
            needsRedraw = true
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
    private var storedNormalStrokeWidth: CGFloat = 3.0
    private var storedNormalFontWeight: Int = 6
    private var storedNormalFontScale: CGFloat = 1.0
    private var currentPlaybackTime: Double = 0
    private var needsRedraw = false

    // MARK: - Text cache

    private var textCache = NSCache<NSString, CachedText>()
    private var specialTextCache = NSCache<NSString, CachedSpecialText>()

    private final class CachedText {
        /// Foreground glyph run, drawn last so the user-visible text
        /// sits on top of the halo.
        let line: CTLine
        /// Optional halo line: the same string laid out with a
        /// significantly heavier font weight in opaque black. Drawing
        /// it underneath the foreground line gives a uniform halo that
        /// matches the foreground's metrics — including for CJK
        /// glyphs, where Core Text's `kCTStrokeWidthAttribute` would
        /// previously paint *inside* the strokes (划伤汉字内部) instead
        /// of around them. Two `CTLineDraw` calls is the entire
        /// per-bullet cost; both lines are cached so the work is
        /// amortised across every frame the bullet stays on screen.
        let haloLine: CTLine?
        let size: CGSize
        let drawInset: CGFloat

        init(line: CTLine, haloLine: CTLine?, size: CGSize, drawInset: CGFloat) {
            self.line = line
            self.haloLine = haloLine
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
        /// Mirrors `item.isSelf` at schedule time. Used by the renderer
        /// to draw a capsule frame around the user's own bullets so
        /// they're visually distinct from everyone else's.
        var isSelf: Bool { item.isSelf }
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
        // Callers hand us a pre-sorted track so route transitions
        // don't spend their first few frames doing an O(n log n)
        // sort on the main actor.
        sourceItems = items
        rebuildTrack()
    }

    /// Inject a single live item at the current playhead and schedule
    /// it for immediate display. Used by the local-echo path after the
    /// user successfully sends their own danmaku — saves a full track
    /// refetch round-trip.
    func appendLive(_ item: DanmakuItemDTO) {
        // Keep `sourceItems` sorted so a future seek+rewind still
        // surfaces the user's bullet in chronological order. We don't
        // bother resorting the whole list: insertion is rare and the
        // active scheduler only cares about `cursor` advancing.
        let insertAt = sourceItems.firstIndex(where: { $0.timeSec > item.timeSec }) ?? sourceItems.count
        sourceItems.insert(item, at: insertAt)
        // Mirror the `shouldInclude` filter so block-level rules still
        // apply consistently to local echoes (self-bullets are exempt
        // from weight-based blocking by design).
        guard shouldInclude(item) else { return }
        // Schedule against `currentPlaybackTime` rather than the item's
        // own timeSec so it shows up *now*, even if the user paused or
        // the playhead drifted.
        schedule(item, at: currentPlaybackTime)
        // Maintain the cursor so the time-driven feeder doesn't replay
        // it as an upcoming item once the playhead crosses timeSec.
        let bound = lowerBound(of: item.timeSec)
        if bound <= cursor {
            cursor += 1
        }
        // Keep the `all` filtered cache in sync so seek-resync still
        // reproduces the bullet later.
        let allInsert = all.firstIndex(where: { $0.timeSec > item.timeSec }) ?? all.count
        all.insert(item, at: allInsert)
        if allInsert <= cursor {
            cursor += 1
        }
        needsRedraw = true
        setNeedsDisplay()
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
        let perItem = item.fontSize > 0 ? CGFloat(item.fontSize) / 25.0 : 1.0
        // Mode-7 (advanced) bullets handle their own typography; the
        // user-tunable scale only affects normal bullets.
        let userScale = item.mode == 7 ? CGFloat(1.0) : storedNormalFontScale
        return baseFontSize * perItem * userScale
    }

    private func resolvedFont(for item: DanmakuItemDTO) -> UIFont {
        let fontSize = resolvedFontSize(for: item)
        let weight = item.mode == 7 ? UIFont.Weight.semibold : Self.fontWeight(forSlot: storedNormalFontWeight)
        let baseFont = UIFont.systemFont(ofSize: fontSize, weight: weight)
        return baseFont.fontDescriptor.withDesign(.rounded)
            .map { UIFont(descriptor: $0, size: fontSize) } ?? baseFont
    }

    private static func fontWeight(forSlot slot: Int) -> UIFont.Weight {
        switch min(max(slot, 1), 9) {
        case 1: return .ultraLight
        case 2: return .thin
        case 3: return .light
        case 4: return .regular
        case 5: return .medium
        case 6: return .semibold
        case 7: return .bold
        case 8: return .heavy
        default: return .black
        }
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

        let mainAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fillColor,
        ]
        let mainStr = NSAttributedString(string: displayText, attributes: mainAttrs)
        let mainLine = CTLineCreateWithAttributedString(mainStr)
        let mainBounds = CTLineGetBoundsWithOptions(mainLine, .useOpticalBounds)

        // Build a heavier-weight black version of the same text and
        // draw it underneath as a halo. We bump the weight slot by
        // one tier per `storedNormalStrokeWidth` step, capped at
        // `.black`, so the halo grows with the user's stroke setting
        // without adding extra draw calls. Mode-7 (advanced) bullets
        // keep their own paint stack.
        var haloLine: CTLine?
        var haloBounds: CGRect = .zero
        if item.mode != 7, storedNormalStrokeWidth > 0 {
            let bumpSlots = max(1, Int(ceil(storedNormalStrokeWidth)))
            let haloSlot = min(9, storedNormalFontWeight + bumpSlots + 1)
            let haloWeight = Self.fontWeight(forSlot: haloSlot)
            let baseHalo = UIFont.systemFont(ofSize: font.pointSize, weight: haloWeight)
            let haloFont = baseHalo.fontDescriptor.withDesign(.rounded)
                .map { UIFont(descriptor: $0, size: font.pointSize) } ?? baseHalo
            let haloAttrs: [NSAttributedString.Key: Any] = [
                .font: haloFont,
                .foregroundColor: UIColor.black,
            ]
            let haloStr = NSAttributedString(string: displayText, attributes: haloAttrs)
            haloLine = CTLineCreateWithAttributedString(haloStr)
            haloBounds = CTLineGetBoundsWithOptions(haloLine!, .useOpticalBounds)
        }

        // The halo glyphs may extend a hair beyond the foreground
        // optical bounds (heavier weight = wider advance widths), so
        // size the cached canvas to fit the union of both lines.
        let unionWidth = max(mainBounds.width, haloBounds.width)
        let unionHeight = max(mainBounds.height, haloBounds.height)
        let drawInset: CGFloat = 2
        let size = CGSize(
            width: ceil(unionWidth) + drawInset * 2,
            height: ceil(unionHeight) + drawInset * 2
        )
        return CachedText(
            line: mainLine,
            haloLine: haloLine,
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
                drawNormalText(ct, at: CGPoint(x: x, y: y), alpha: 1.0, isSelf: dm.isSelf, in: ctx, viewport: size)

            case .top:
                guard let ct = dm.cachedText else { continue }
                let x = (size.width - ct.size.width) / 2
                let y = scrollLaneH * (CGFloat(dm.lane) + 0.5) - ct.size.height / 2
                drawNormalText(ct, at: CGPoint(x: x, y: y), alpha: 1.0, isSelf: dm.isSelf, in: ctx, viewport: size)

            case .bottom:
                guard let ct = dm.cachedText else { continue }
                let x = (size.width - ct.size.width) / 2
                let y = size.height - scrollLaneH * (CGFloat(dm.lane) + 1.5)
                drawNormalText(ct, at: CGPoint(x: x, y: y), alpha: 1.0, isSelf: dm.isSelf, in: ctx, viewport: size)

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
        isSelf: Bool,
        in context: CGContext,
        viewport: CGSize
    ) {
        guard alpha > 0.01 else { return }
        guard origin.x + cached.size.width > 0,
              origin.x < viewport.width,
              origin.y + cached.size.height > 0,
              origin.y < viewport.height else { return }

        if isSelf {
            // Frame the user's own bullet so they can spot it in the
            // crowd. We use the accent tint with a translucent fill so
            // it reads as "yours" without overpowering the text.
            let inset: CGFloat = 2
            let frame = CGRect(
                x: origin.x - inset,
                y: origin.y - inset,
                width: cached.size.width + inset * 2,
                height: cached.size.height + inset * 2
            )
            let radius = min(frame.height / 2, 10)
            let path = CGPath(
                roundedRect: frame,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            context.saveGState()
            context.setAlpha(alpha)
            context.addPath(path)
            context.setFillColor(UIColor(red: 1.0, green: 0.42, blue: 0.65, alpha: 0.18).cgColor)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(UIColor(red: 1.0, green: 0.42, blue: 0.65, alpha: 0.95).cgColor)
            context.setLineWidth(1.4)
            context.strokePath()
            context.restoreGState()
        }

        context.saveGState()
        context.setAlpha(alpha)
        context.textMatrix = .identity
        context.translateBy(
            x: origin.x + cached.drawInset,
            y: origin.y + cached.size.height - cached.drawInset
        )
        context.scaleBy(x: 1, y: -1)
        // Halo first (heavier-weight black laid out at the same
        // baseline), foreground glyphs on top — two `CTLineDraw`
        // calls total, both pre-cached.
        if let halo = cached.haloLine {
            context.textPosition = .zero
            CTLineDraw(halo, context)
        }
        context.textPosition = .zero
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
