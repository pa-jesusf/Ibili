import SwiftUI
import UIKit

/// UIScrollView owns deceleration, pinch rubber-banding and content bounds.
/// Image quality upgrades retain the user's zoom and focal point.
struct NativeImageZoomView: UIViewRepresentable {
    let image: UIImage?
    @Binding var isZoomed: Bool

    func makeUIView(context: Context) -> ImageZoomScrollView {
        ImageZoomScrollView()
    }

    func updateUIView(_ view: ImageZoomScrollView, context: Context) {
        view.onZoomChanged = { value in
            // Delegate callbacks can occur during SwiftUI layout.
            DispatchQueue.main.async { if isZoomed != value { isZoomed = value } }
        }
        view.setImage(image)
    }

    static func dismantleUIView(_ view: ImageZoomScrollView, coordinator: ()) {
        view.onZoomChanged = nil
        view.delegate = nil
    }
}

final class ImageZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var fittedSize: CGSize = .zero
    private var viewportSize: CGSize = .zero
    private var reportedZoomed = false
    private var isUpdatingLayout = false
    var onZoomChanged: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        minimumZoomScale = 1
        maximumZoomScale = 4
        bounces = true
        bouncesZoom = true
        decelerationRate = .normal
        panGestureRecognizer.isEnabled = false
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage?) {
        guard imageView.image !== image else { return }
        imageView.image = image
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isUpdatingLayout, let image = imageView.image,
              bounds.width > 0, bounds.height > 0 else { return }
        let size = ImageZoomGeometry.fittedSize(image: image.size, viewport: bounds.size)
        guard size != fittedSize || viewportSize != bounds.size else {
            centerImage()
            return
        }
        isUpdatingLayout = true
        let oldZoom = zoomScale
        let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: imageView)
        let normalized = CGPoint(x: center.x / max(fittedSize.width, 1), y: center.y / max(fittedSize.height, 1))
        let hadLayout = fittedSize != .zero
        setZoomScale(1, animated: false)
        fittedSize = size
        viewportSize = bounds.size
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        setZoomScale(oldZoom, animated: false)
        centerImage()
        let focus = hadLayout ? normalized : CGPoint(x: 0.5, y: 0.5)
        let offset = CGPoint(x: focus.x * contentSize.width - bounds.width / 2,
                             y: focus.y * contentSize.height - bounds.height / 2)
        contentOffset = CGPoint(
            x: min(max(offset.x, -contentInset.left), max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)),
            y: min(max(offset.y, -contentInset.top), max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom))
        )
        isUpdatingLayout = false
        reportZoom()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !isUpdatingLayout else { return }
        centerImage()
        reportZoom()
    }

    private func centerImage() {
        let inset = ImageZoomGeometry.centeringInset(content: contentSize, viewport: bounds.size)
        let next = UIEdgeInsets(top: inset.y, left: inset.x, bottom: inset.y, right: inset.x)
        if contentInset != next { contentInset = next }
    }

    private func reportZoom() {
        let zoomed = zoomScale > 1.01
        panGestureRecognizer.isEnabled = zoomed
        guard reportedZoomed != zoomed else { return }
        reportedZoomed = zoomed
        onZoomChanged?(zoomed)
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard imageView.image != nil else { return }
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let size = CGSize(width: bounds.width / 2.4, height: bounds.height / 2.4)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}
