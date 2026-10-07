import CoreGraphics
import QuartzCore

/// Reusable bitmap layer shared by ordinary and advanced danmaku.
final class DanmakuBulletLayer: CALayer {
    private lazy var contentLayer = CALayer()

    override init() {
        super.init()
        setup()
    }

    override init(layer: Any) {
        // Core Animation copies the existing subtree for presentation().
        // Its read-only copy must not run setup() or add any sublayers.
        super.init(layer: layer)
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

    func configure(image: CGImage?, size: CGSize, isSelf: Bool, contentsScale: CGFloat) {
        bounds = CGRect(origin: .zero, size: size)
        contentLayer.contentsScale = contentsScale
        contentLayer.frame = bounds
        contentLayer.contents = image
        configureSelfFrame(isSelf)
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
        backgroundColor = CGColor(srgbRed: 1, green: 0.42, blue: 0.65, alpha: 0.18)
        borderColor = CGColor(srgbRed: 1, green: 0.42, blue: 0.65, alpha: 0.95)
        borderWidth = 1.2
        cornerRadius = min(bounds.height / 2, 8)
    }
}
