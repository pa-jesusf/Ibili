import UIKit
import AVFoundation
import CoreText

// MARK: - Lane allocation

/// Timeline-based lane allocator shared by the renderer and unit tests.
///
/// Lane occupancy controls collision placement, not danmaku capacity. When all
/// lanes are busy, the earliest reusable lane is selected so no source item is
/// silently dropped.
struct DanmakuLaneAllocator {
    private(set) var scrollingFreeAt: [Double]
    private(set) var topFreeAt: [Double]
    private(set) var bottomFreeAt: [Double]

    init(laneCount: Int) {
        let resolvedCount = max(1, laneCount)
        scrollingFreeAt = Array(repeating: 0, count: resolvedCount)
        let staticCount = max(resolvedCount / 3, 2)
        topFreeAt = Array(repeating: 0, count: staticCount)
        bottomFreeAt = Array(repeating: 0, count: staticCount)
    }

    mutating func reserveScrollingLane(
        at startTime: Double,
        duration: Double
    ) -> Int {
        let lane = Self.availableLane(in: scrollingFreeAt, at: startTime)
        scrollingFreeAt[lane] = startTime + duration * 0.45
        return lane
    }

    mutating func reserveTopLane(
        at startTime: Double,
        duration: Double
    ) -> Int {
        Self.reserveStaticLane(
            in: &topFreeAt,
            at: startTime,
            duration: duration
        )
    }

    mutating func reserveBottomLane(
        at startTime: Double,
        duration: Double
    ) -> Int {
        Self.reserveStaticLane(
            in: &bottomFreeAt,
            at: startTime,
            duration: duration
        )
    }

    private static func availableLane(
        in pool: [Double],
        at startTime: Double
    ) -> Int {
        if let lane = pool.firstIndex(where: { $0 <= startTime }) {
            return lane
        }
        return pool.indices.min(by: { pool[$0] < pool[$1] }) ?? 0
    }

    private static func reserveStaticLane(
        in pool: inout [Double],
        at startTime: Double,
        duration: Double
    ) -> Int {
        let lane = availableLane(in: pool, at: startTime)
        pool[lane] = startTime + duration
        return lane
    }
}

// MARK: - Reusable render layers

private final class DanmakuCachedText {
    let image: UIImage
    let size: CGSize

    init(image: UIImage, size: CGSize) {
        self.image = image
        self.size = size
    }

    var cost: Int {
        guard let image = image.cgImage else { return 0 }
        return image.bytesPerRow * image.height
    }
}

private final class DanmakuCachedSpecialText {
    let image: UIImage
    let size: CGSize
    let drawOffset: CGPoint

    init(image: UIImage, size: CGSize, drawOffset: CGPoint) {
        self.image = image
        self.size = size
        self.drawOffset = drawOffset
    }

    var cost: Int {
        guard let image = image.cgImage else { return 0 }
        return image.bytesPerRow * image.height
    }
}

private final class DanmakuBulletLayer: CALayer {
    private let contentLayer = CALayer()

    override init() {
        super.init()
        setup()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "opacity": NSNull(),
            "contents": NSNull(),
            "sublayers": NSNull(),
        ]
        contentLayer.actions = actions
        contentLayer.contentsGravity = .resize
        addSublayer(contentLayer)
    }

    func configureText(
        _ cached: DanmakuCachedText,
        isSelf: Bool,
        contentsScale: CGFloat
    ) {
        bounds = CGRect(origin: .zero, size: cached.size)
        contentLayer.contentsScale = contentsScale
        contentLayer.frame = bounds
        contentLayer.contents = cached.image.cgImage
        configureSelfFrame(isSelf)
        shouldRasterize = false
    }

    func configureSpecial(
        _ cached: DanmakuCachedSpecialText,
        contentsScale: CGFloat
    ) {
        bounds = CGRect(origin: .zero, size: cached.size)
        contentLayer.contentsScale = contentsScale
        contentLayer.frame = bounds
        contentLayer.contents = cached.image.cgImage
        configureSelfFrame(false)
        shouldRasterize = false
    }

    func prepareForReuse() {
        removeAllAnimations()
        contentLayer.removeAllAnimations()
        contentLayer.contents = nil
        opacity = 1
        transform = CATransform3DIdentity
        backgroundColor = nil
        borderColor = nil
        borderWidth = 0
        cornerRadius = 0
        shouldRasterize = false
        removeFromSuperlayer()
    }

    private func configureSelfFrame(_ isSelf: Bool) {
        guard isSelf else {
            backgroundColor = nil
            borderColor = nil
            borderWidth = 0
            cornerRadius = 0
            return
        }
        backgroundColor = UIColor(red: 1, green: 0.42, blue: 0.65, alpha: 0.18).cgColor
        borderColor = UIColor(red: 1, green: 0.42, blue: 0.65, alpha: 0.95).cgColor
        borderWidth = 1.2
        cornerRadius = min(bounds.height / 2, 8)
    }
}

// MARK: - Synchronized danmaku renderer

/// GPU-composited danmaku renderer synchronized directly to the active
/// `AVPlayerItem` timeline.
///
/// Source items remain as plain data. Only bullets intersecting a small media
/// time window are materialized as reusable Core Animation layers. Movement,
/// pause, rate changes and seeking are then driven by `AVSynchronizedLayer`
/// rather than main-thread per-frame drawing.
@MainActor
final class DanmakuCanvasView: UIView {

    // MARK: Configuration

    var laneCount: Int = 14 {
        didSet {
            guard laneCount != oldValue else { return }
            resynchronizePresentation()
        }
    }

    var scrollDuration: Double = 8 {
        didSet {
            scrollDuration = max(0.1, scrollDuration)
            guard scrollDuration != oldValue else { return }
            resynchronizePresentation()
        }
    }

    var staticDuration: Double = 4 {
        didSet {
            staticDuration = max(0.1, staticDuration)
            guard staticDuration != oldValue else { return }
            resynchronizePresentation()
        }
    }

    var blockLevel: Int {
        get { storedBlockLevel }
        set {
            let clamped = min(max(newValue, 0), 11)
            guard storedBlockLevel != clamped else { return }
            storedBlockLevel = clamped
            rebuildTrack(clearTextCaches: false)
        }
    }

    var preferredFrameRate: Int {
        get { storedFrameRate }
        set {
            let resolved = DanmakuFrameRateOption.resolve(newValue)
            guard storedFrameRate != resolved else { return }
            storedFrameRate = resolved
            resynchronizePresentation()
        }
    }

    var normalStrokeWidth: CGFloat {
        get { storedNormalStrokeWidth }
        set {
            let clamped = max(0, min(newValue, 6))
            guard storedNormalStrokeWidth != clamped else { return }
            storedNormalStrokeWidth = clamped
            invalidateNormalTextStyle()
        }
    }

    var normalFontWeight: Int {
        get { storedNormalFontWeight }
        set {
            let clamped = max(1, min(newValue, 9))
            guard storedNormalFontWeight != clamped else { return }
            storedNormalFontWeight = clamped
            invalidateNormalTextStyle()
        }
    }

    var normalFontScale: CGFloat {
        get { storedNormalFontScale }
        set {
            let clamped = max(0.6, min(newValue, 1.6))
            guard storedNormalFontScale != clamped else { return }
            storedNormalFontScale = clamped
            invalidateNormalTextStyle()
        }
    }

    private let schedulerInterval: Double = 0.25
    private let schedulingLookAhead: Double = 2
    private let resynchronizationLookBehind: Double = 30
    private let seekResyncThreshold: Double = 1.25
    private let recycleGrace: Double = 0.2
    private let maximumPooledLayers = 128

    // MARK: Timeline state

    private var sourceItems: [DanmakuItemDTO] = []
    private var all: [DanmakuItemDTO] = []
    private var cursor = 0
    private var laneAllocator = DanmakuLaneAllocator(laneCount: 14)
    private var activeLayers: [ActiveLayer] = []
    private var layerPool: [DanmakuBulletLayer] = []
    private var lastObservedPlaybackTime: Double?

    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var currentItemObservation: NSKeyValueObservation?
    private var timeJumpObserver: NSObjectProtocol?
    private var synchronizedLayer: AVSynchronizedLayer?
    private var normalContainerLayer: CALayer?
    private var specialContainerLayer: CALayer?
    private var lastLayoutSize: CGSize = .zero
    private var layoutResynchronizationWork: DispatchWorkItem?

    private var storedBlockLevel = 0
    private var storedFrameRate = 60
    private var storedNormalStrokeWidth: CGFloat = 3
    private var storedNormalFontWeight = 6
    private var storedNormalFontScale: CGFloat = 1

    private var textCache = NSCache<NSString, DanmakuCachedText>()
    private var specialTextCache = NSCache<NSString, DanmakuCachedSpecialText>()

    private struct ActiveLayer {
        let layer: DanmakuBulletLayer
        let endTime: Double
    }

    private enum DanmakuMode {
        case scroll
        case top
        case bottom
        case special(SpecialDanmakuDescriptor)
    }

    // MARK: Lifecycle

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
        layer.masksToBounds = true
        textCache.countLimit = 768
        textCache.totalCostLimit = 24 * 1024 * 1024
        specialTextCache.countLimit = 128
        specialTextCache.totalCostLimit = 12 * 1024 * 1024
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        synchronizedLayer?.frame = bounds
        normalContainerLayer?.frame = bounds
        specialContainerLayer?.frame = bounds
        CATransaction.commit()

        guard bounds.width > 0, bounds.height > 0 else { return }
        guard abs(lastLayoutSize.width - bounds.width) > 0.5
                || abs(lastLayoutSize.height - bounds.height) > 0.5 else {
            return
        }
        lastLayoutSize = bounds.size
        scheduleLayoutResynchronization()
    }

    deinit {
        MainActor.assumeIsolated {
            layoutResynchronizationWork?.cancel()
            removeObservers()
        }
    }

    // MARK: Public API

    func setItems(_ items: [DanmakuItemDTO]) {
        sourceItems = items
        rebuildTrack(clearTextCaches: true)
    }

    func mergeItems(_ items: [DanmakuItemDTO]) {
        guard !items.isEmpty else { return }
        let sortedItems = items.sorted { $0.timeSec < $1.timeSec }
        sourceItems = Self.mergingSortedDanmaku(sourceItems, with: sortedItems)
        all = Self.mergingSortedDanmaku(all, with: sortedItems.filter(shouldInclude))
        resynchronizePresentation()
    }

    func appendLive(_ item: DanmakuItemDTO) {
        let sourceInsert = sourceItems.firstIndex(where: { $0.timeSec > item.timeSec }) ?? sourceItems.count
        sourceItems.insert(item, at: sourceInsert)
        guard shouldInclude(item) else { return }

        let allInsert = all.firstIndex(where: { $0.timeSec > item.timeSec }) ?? all.count
        all.insert(item, at: allInsert)
        if allInsert <= cursor {
            cursor += 1
        }

        let now = resolvedPlaybackTime()
        materialize(
            item,
            startTime: now,
            currentTime: now
        )
    }

    func attach(_ player: AVPlayer) {
        if self.player === player, currentItemObservation != nil {
            if synchronizedLayer?.playerItem !== player.currentItem {
                installSynchronizedLayer(for: player.currentItem)
            }
            return
        }

        removeObservers()
        self.player = player
        addScheduler(to: player)
        currentItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] observedPlayer, _ in
            Task { @MainActor [weak self] in
                guard self?.player === observedPlayer else { return }
                self?.installSynchronizedLayer(for: observedPlayer.currentItem)
            }
        }
    }

    func detach() {
        removeObservers()
        player = nil
        installSynchronizedLayer(for: nil)
    }

    static func effectiveFrameRate(requested: Int, maximumFramesPerSecond: Int) -> Int {
        min(
            DanmakuFrameRateOption.resolve(requested),
            max(1, maximumFramesPerSecond)
        )
    }

    static func normalTrackHeight(
        containerHeight: CGFloat,
        laneCount: Int,
        fontSize: CGFloat,
        lineHeightMultiplier: CGFloat = 1.6
    ) -> CGFloat {
        let minimumHeight: CGFloat = 20
        let distributedHeight = containerHeight / CGFloat(max(1, laneCount) + 1)
        let typographyHeight = ceil(max(1, fontSize) * max(1, lineHeightMultiplier))
        return min(
            max(minimumHeight, distributedHeight),
            max(minimumHeight, typographyHeight)
        )
    }

    // MARK: Scheduling

    private func addScheduler(to player: AVPlayer) {
        let interval = CMTime(seconds: schedulerInterval, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds.isFinite ? max(0, time.seconds) : 0
            Task { @MainActor [weak self] in
                self?.handleSchedulerTick(at: seconds)
            }
        }
    }

    private func handleSchedulerTick(at now: Double) {
        if let lastObservedPlaybackTime,
           now + 0.05 < lastObservedPlaybackTime
                || now - lastObservedPlaybackTime > seekResyncThreshold {
            resynchronizePresentation(at: now)
            return
        }

        lastObservedPlaybackTime = now
        recycleExpiredLayers(at: now)
        scheduleItems(through: now + schedulingLookAhead, currentTime: now)
    }

    private func installSynchronizedLayer(for item: AVPlayerItem?) {
        removeTimeJumpObserver()
        recycleAllActiveLayers()
        synchronizedLayer?.removeFromSuperlayer()
        synchronizedLayer = nil
        normalContainerLayer = nil
        specialContainerLayer = nil
        lastObservedPlaybackTime = nil

        guard let item else { return }
        let syncLayer = AVSynchronizedLayer(playerItem: item)
        syncLayer.frame = bounds
        syncLayer.masksToBounds = true
        let normalLayer = makeContainerLayer()
        let specialLayer = makeContainerLayer()
        syncLayer.addSublayer(normalLayer)
        syncLayer.addSublayer(specialLayer)
        layer.addSublayer(syncLayer)
        synchronizedLayer = syncLayer
        normalContainerLayer = normalLayer
        specialContainerLayer = specialLayer

        timeJumpObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemTimeJumped,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resynchronizePresentation()
            }
        }
        resynchronizePresentation()
    }

    private func resynchronizePresentation(at explicitTime: Double? = nil) {
        guard synchronizedLayer != nil, bounds.width > 0, bounds.height > 0 else { return }
        let now = explicitTime ?? resolvedPlaybackTime()
        recycleAllActiveLayers()
        laneAllocator = DanmakuLaneAllocator(laneCount: laneCount)
        cursor = lowerBound(of: Float(max(0, now - resynchronizationLookBehind)))
        scheduleItems(through: now + schedulingLookAhead, currentTime: now)
        lastObservedPlaybackTime = now
    }

    private func scheduleItems(through horizon: Double, currentTime: Double) {
        while cursor < all.count, Double(all[cursor].timeSec) <= horizon {
            let item = all[cursor]
            materialize(
                item,
                startTime: max(0, Double(item.timeSec)),
                currentTime: currentTime
            )
            cursor += 1
        }
    }

    private func materialize(
        _ item: DanmakuItemDTO,
        startTime: Double,
        currentTime: Double
    ) {
        guard synchronizedLayer != nil else { return }

        let mode: DanmakuMode
        let displayText: String
        let duration: Double
        switch item.mode {
        case 4:
            mode = .bottom
            displayText = item.text
            duration = staticDuration
        case 5:
            mode = .top
            displayText = item.text
            duration = staticDuration
        case 7:
            guard let descriptor = SpecialDanmakuDescriptor.parse(rawText: item.text) else { return }
            mode = .special(descriptor)
            displayText = descriptor.text
            duration = descriptor.displayDuration
        default:
            mode = .scroll
            displayText = item.text
            duration = scrollDuration
        }

        let endTime = startTime + duration
        let isCurrentlyRelevant = endTime > currentTime - recycleGrace
        let lane: Int
        switch mode {
        case .scroll:
            lane = laneAllocator.reserveScrollingLane(
                at: startTime,
                duration: duration
            )
        case .top:
            lane = laneAllocator.reserveTopLane(
                at: startTime,
                duration: duration
            )
        case .bottom:
            lane = laneAllocator.reserveBottomLane(
                at: startTime,
                duration: duration
            )
        case .special:
            lane = 0
        }

        guard isCurrentlyRelevant else { return }

        let bulletLayer = dequeueLayer()
        let scale = resolvedContentsScale()
        let cacheText = item.mode == 7 ? item.text : displayText
        let textKey = "\(cacheText)_\(item.color)_\(item.fontSize)_\(item.mode)" as NSString

        switch mode {
        case .special(let descriptor):
            let cached = cachedSpecialText(
                key: textKey,
                displayText: displayText,
                item: item,
                descriptor: descriptor
            )
            bulletLayer.configureSpecial(cached, contentsScale: scale)
            specialContainerLayer?.addSublayer(bulletLayer)
            configureSpecialAnimations(
                on: bulletLayer,
                cached: cached,
                descriptor: descriptor,
                startTime: startTime
            )

        case .scroll, .top, .bottom:
            let cached = cachedNormalText(key: textKey, displayText: displayText, item: item)
            bulletLayer.configureText(cached, isSelf: item.isSelf, contentsScale: scale)
            normalContainerLayer?.addSublayer(bulletLayer)
            configureNormalAnimations(
                on: bulletLayer,
                cached: cached,
                mode: mode,
                lane: lane,
                startTime: startTime,
                duration: duration
            )
        }

        activeLayers.append(ActiveLayer(
            layer: bulletLayer,
            endTime: endTime
        ))
    }

    // MARK: Animation construction

    private func configureNormalAnimations(
        on layer: DanmakuBulletLayer,
        cached: DanmakuCachedText,
        mode: DanmakuMode,
        lane: Int,
        startTime: Double,
        duration: Double
    ) {
        let laneHeight = Self.normalTrackHeight(
            containerHeight: bounds.height,
            laneCount: laneCount,
            fontSize: baseFontSize * storedNormalFontScale
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        switch mode {
        case .scroll:
            let y = laneHeight * (CGFloat(lane) + 0.5)
            let startX = bounds.width + cached.size.width / 2
            let endX = -cached.size.width / 2
            layer.position = CGPoint(x: endX, y: y)
            layer.opacity = 1

            let movement = CABasicAnimation(keyPath: "position.x")
            movement.fromValue = startX
            movement.toValue = endX
            configure(
                movement,
                beginTime: startTime,
                duration: duration,
                timingFunction: CAMediaTimingFunction(name: .linear)
            )
            layer.add(movement, forKey: "danmaku.scroll")

        case .top, .bottom:
            let y: CGFloat
            if case .top = mode {
                y = laneHeight * (CGFloat(lane) + 0.5)
            } else {
                y = bounds.height - laneHeight * (CGFloat(lane) + 1.5) + cached.size.height / 2
            }
            layer.position = CGPoint(x: bounds.midX, y: y)
            layer.opacity = 0
            addVisibilityAnimation(
                to: layer,
                startAlpha: 1,
                endAlpha: 1,
                beginTime: startTime,
                duration: duration
            )

        case .special:
            break
        }
        CATransaction.commit()
    }

    private func configureSpecialAnimations(
        on layer: DanmakuBulletLayer,
        cached: DanmakuCachedSpecialText,
        descriptor: SpecialDanmakuDescriptor,
        startTime: Double
    ) {
        let startOrigin = descriptor.position(at: 0, in: bounds.size)
        let endOrigin = descriptor.position(
            at: descriptor.delay + descriptor.moveDuration,
            in: bounds.size
        )
        let startPosition = CGPoint(
            x: startOrigin.x + cached.drawOffset.x + cached.size.width / 2,
            y: startOrigin.y + cached.drawOffset.y + cached.size.height / 2
        )
        let endPosition = CGPoint(
            x: endOrigin.x + cached.drawOffset.x + cached.size.width / 2,
            y: endOrigin.y + cached.drawOffset.y + cached.size.height / 2
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = endPosition
        layer.opacity = 0

        let remainingDuration = max(0, descriptor.displayDuration - descriptor.delay)
        let movementDuration = min(descriptor.moveDuration, remainingDuration)
        if movementDuration > 0.001, startPosition != endPosition {
            let movement = CABasicAnimation(keyPath: "position")
            movement.fromValue = NSValue(cgPoint: startPosition)
            movement.toValue = NSValue(cgPoint: endPosition)
            let timingFunction: CAMediaTimingFunction
            switch descriptor.easing {
            case .easeInCubic:
                timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.55,
                    0.055,
                    0.675,
                    0.19
                )
            case .linear:
                timingFunction = CAMediaTimingFunction(name: .linear)
            }
            configure(
                movement,
                beginTime: startTime + descriptor.delay,
                duration: movementDuration,
                timingFunction: timingFunction
            )
            layer.add(movement, forKey: "danmaku.special.position")
        } else {
            layer.position = startPosition
        }

        addVisibilityAnimation(
            to: layer,
            startAlpha: descriptor.startAlpha,
            endAlpha: descriptor.endAlpha,
            beginTime: startTime,
            duration: descriptor.displayDuration
        )
        CATransaction.commit()
    }

    private func addVisibilityAnimation(
        to layer: CALayer,
        startAlpha: CGFloat,
        endAlpha: CGFloat,
        beginTime: Double,
        duration: Double
    ) {
        let visibility = CAKeyframeAnimation(keyPath: "opacity")
        visibility.values = [0, startAlpha, endAlpha, 0]
        visibility.keyTimes = [0, 0.001, 0.999, 1]
        visibility.calculationMode = .linear
        configure(
            visibility,
            beginTime: beginTime,
            duration: max(0.001, duration),
            timingFunction: nil
        )
        layer.add(visibility, forKey: "danmaku.visibility")
    }

    private func configure(
        _ animation: CAAnimation,
        beginTime: Double,
        duration: Double,
        timingFunction: CAMediaTimingFunction?
    ) {
        animation.beginTime = mediaTimelineBeginTime(beginTime)
        animation.duration = max(0.001, duration)
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        animation.timingFunction = timingFunction
        let frameRate = Float(effectiveFrameRate)
        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: frameRate,
            maximum: frameRate,
            preferred: frameRate
        )
    }

    private func mediaTimelineBeginTime(_ seconds: Double) -> CFTimeInterval {
        seconds > 0 ? seconds : AVCoreAnimationBeginTimeAtZero
    }

    private var effectiveFrameRate: Int {
        let maximum = window?.windowScene?.screen.maximumFramesPerSecond
            ?? UIScreen.main.maximumFramesPerSecond
        return Self.effectiveFrameRate(
            requested: storedFrameRate,
            maximumFramesPerSecond: maximum
        )
    }

    // MARK: Text preparation

    private let baseFontSize: CGFloat = 18
    private let maxRasterSize: CGFloat = 4096

    private func cachedNormalText(
        key: NSString,
        displayText: String,
        item: DanmakuItemDTO
    ) -> DanmakuCachedText {
        if let cached = textCache.object(forKey: key) {
            return cached
        }
        let cached = makeNormalText(displayText: displayText, item: item)
        textCache.setObject(cached, forKey: key, cost: cached.cost)
        return cached
    }

    private func cachedSpecialText(
        key: NSString,
        displayText: String,
        item: DanmakuItemDTO,
        descriptor: SpecialDanmakuDescriptor
    ) -> DanmakuCachedSpecialText {
        if let cached = specialTextCache.object(forKey: key) {
            return cached
        }
        let cached = makeSpecialText(
            displayText: displayText,
            item: item,
            descriptor: descriptor
        )
        specialTextCache.setObject(cached, forKey: key, cost: cached.cost)
        return cached
    }

    private func makeNormalText(
        displayText: String,
        item: DanmakuItemDTO
    ) -> DanmakuCachedText {
        let font = resolvedFont(for: item)
        let foregroundText = NSAttributedString(string: displayText, attributes: [
            .font: font,
            .foregroundColor: resolvedTextColor(for: item),
        ])
        let foregroundLine = CTLineCreateWithAttributedString(foregroundText)
        let opticalBounds = CTLineGetBoundsWithOptions(foregroundLine, .useOpticalBounds)

        let haloLine: CTLine?
        let haloBlur: CGFloat
        if storedNormalStrokeWidth > 0 {
            let haloText = NSAttributedString(string: displayText, attributes: [
                .font: font,
                .foregroundColor: UIColor.black,
            ])
            haloLine = CTLineCreateWithAttributedString(haloText)
            haloBlur = max(0.8, storedNormalStrokeWidth * 0.95)
        } else {
            haloLine = nil
            haloBlur = 0
        }

        let drawInset = max(2, ceil(haloBlur * 2.2) + 1)
        let contentBounds = CGRect(
            x: floor(opticalBounds.minX),
            y: floor(opticalBounds.minY),
            width: max(1, ceil(opticalBounds.maxX) - floor(opticalBounds.minX)),
            height: max(1, ceil(opticalBounds.maxY) - floor(opticalBounds.minY))
        )
        let size = CGSize(
            width: min(maxRasterSize, contentBounds.width + drawInset * 2),
            height: min(maxRasterSize, contentBounds.height + drawInset * 2)
        )

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = resolvedContentsScale()
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cgContext = context.cgContext
            cgContext.setAllowsAntialiasing(true)
            cgContext.setShouldAntialias(true)
            cgContext.setAllowsFontSmoothing(true)
            cgContext.setShouldSmoothFonts(true)
            cgContext.textMatrix = .identity
            cgContext.translateBy(x: drawInset, y: size.height - drawInset)
            cgContext.scaleBy(x: 1, y: -1)

            if let haloLine {
                cgContext.setShadow(
                    offset: .zero,
                    blur: haloBlur,
                    color: UIColor.black.cgColor
                )
                cgContext.textPosition = .zero
                CTLineDraw(haloLine, cgContext)
                cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            }

            cgContext.textPosition = .zero
            CTLineDraw(foregroundLine, cgContext)
        }
        return DanmakuCachedText(image: image, size: size)
    }

    private func makeSpecialText(
        displayText: String,
        item: DanmakuItemDTO,
        descriptor: SpecialDanmakuDescriptor
    ) -> DanmakuCachedSpecialText {
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
            with: CGSize(width: maxRasterSize, height: maxRasterSize),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let textSize = CGSize(
            width: max(1, min(maxRasterSize, ceil(measured.width))),
            height: max(1, min(maxRasterSize, ceil(measured.height)))
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
        format.scale = resolvedContentsScale()
        let image = UIGraphicsImageRenderer(size: rasterSize, format: format).image { context in
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

        return DanmakuCachedSpecialText(
            image: image,
            size: rasterSize,
            drawOffset: rasterBounds.origin
        )
    }

    private func resolvedFontSize(for item: DanmakuItemDTO) -> CGFloat {
        let perItem = item.fontSize > 0 ? CGFloat(item.fontSize) / 25 : 1
        let userScale = item.mode == 7 ? CGFloat(1) : storedNormalFontScale
        return baseFontSize * perItem * userScale
    }

    private func resolvedFont(for item: DanmakuItemDTO) -> UIFont {
        let fontSize = resolvedFontSize(for: item)
        let weight = item.mode == 7
            ? UIFont.Weight.semibold
            : Self.fontWeight(forSlot: storedNormalFontWeight)
        let baseFont = UIFont.systemFont(ofSize: fontSize, weight: weight)
        return baseFont.fontDescriptor.withDesign(.rounded)
            .map { UIFont(descriptor: $0, size: fontSize) }
            ?? baseFont
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
        let red = CGFloat((item.color >> 16) & 0xFF) / 255
        let green = CGFloat((item.color >> 8) & 0xFF) / 255
        let blue = CGFloat(item.color & 0xFF) / 255
        return UIColor(red: red, green: green, blue: blue, alpha: 1)
    }

    private func resolvedContentsScale() -> CGFloat {
        window?.screen.scale ?? UIScreen.main.scale
    }

    private func makeContainerLayer() -> CALayer {
        let container = CALayer()
        container.frame = bounds
        container.masksToBounds = true
        container.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "sublayers": NSNull(),
        ]
        return container
    }

    // MARK: Layer reuse

    private func dequeueLayer() -> DanmakuBulletLayer {
        if let layer = layerPool.popLast() {
            return layer
        }
        return DanmakuBulletLayer()
    }

    private func recycleExpiredLayers(at currentTime: Double) {
        var survivors: [ActiveLayer] = []
        survivors.reserveCapacity(activeLayers.count)
        for active in activeLayers {
            if active.endTime < currentTime - recycleGrace {
                recycle(active.layer)
            } else {
                survivors.append(active)
            }
        }
        activeLayers = survivors
    }

    private func recycleAllActiveLayers() {
        activeLayers.forEach { recycle($0.layer) }
        activeLayers.removeAll(keepingCapacity: true)
    }

    private func recycle(_ layer: DanmakuBulletLayer) {
        layer.prepareForReuse()
        if layerPool.count < maximumPooledLayers {
            layerPool.append(layer)
        }
    }

    // MARK: Track and observer maintenance

    private func rebuildTrack(clearTextCaches: Bool) {
        all = sourceItems.filter(shouldInclude)
        if clearTextCaches {
            textCache.removeAllObjects()
            specialTextCache.removeAllObjects()
        }
        resynchronizePresentation()
    }

    private func invalidateNormalTextStyle() {
        textCache.removeAllObjects()
        resynchronizePresentation()
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

    private func scheduleLayoutResynchronization() {
        layoutResynchronizationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.layoutResynchronizationWork = nil
            self.resynchronizePresentation()
        }
        layoutResynchronizationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func resolvedPlaybackTime() -> Double {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return 0 }
        return max(0, seconds)
    }

    private func removeObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        removeTimeJumpObserver()
    }

    private func removeTimeJumpObserver() {
        if let timeJumpObserver {
            NotificationCenter.default.removeObserver(timeJumpObserver)
        }
        timeJumpObserver = nil
    }

    private func lowerBound(of time: Float) -> Int {
        var lower = 0
        var upper = all.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if all[middle].timeSec < time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func mergingSortedDanmaku(
        _ lhs: [DanmakuItemDTO],
        with rhs: [DanmakuItemDTO]
    ) -> [DanmakuItemDTO] {
        var merged: [DanmakuItemDTO] = []
        merged.reserveCapacity(lhs.count + rhs.count)
        var lhsIndex = 0
        var rhsIndex = 0
        var seen = Set<String>()

        func key(_ item: DanmakuItemDTO) -> String {
            "\(item.timeSec)|\(item.mode)|\(item.color)|\(item.fontSize)|\(item.midHash)|\(item.text)"
        }

        func appendIfNeeded(_ item: DanmakuItemDTO) {
            if seen.insert(key(item)).inserted {
                merged.append(item)
            }
        }

        while lhsIndex < lhs.count || rhsIndex < rhs.count {
            if rhsIndex >= rhs.count
                || (lhsIndex < lhs.count && lhs[lhsIndex].timeSec <= rhs[rhsIndex].timeSec) {
                appendIfNeeded(lhs[lhsIndex])
                lhsIndex += 1
            } else {
                appendIfNeeded(rhs[rhsIndex])
                rhsIndex += 1
            }
        }
        return merged
    }
}
