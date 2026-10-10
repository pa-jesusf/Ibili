import UIKit

/// AVKit's content overlay can report zero top inset while its fullscreen
/// window still has a camera cutout. Use the actual window's safe-area boundary
/// in local coordinates; inline players below that boundary keep their height.
@MainActor
final class PlayerDanmakuOverlayView: UIView {
    private let canvas: DanmakuCanvasView

    init(canvas: DanmakuCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = true
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let safeTop = window.map {
            convert(CGPoint(x: $0.bounds.midX, y: $0.bounds.minY + $0.safeAreaInsets.top), from: $0).y
        } ?? 0
        let top = min(bounds.height, max(0, safeAreaInsets.top, safeTop - bounds.minY))
        let target = CGRect(x: bounds.minX, y: bounds.minY + top, width: bounds.width, height: max(0, bounds.height - top))
        if canvas.frame != target { canvas.frame = target }
    }
}
