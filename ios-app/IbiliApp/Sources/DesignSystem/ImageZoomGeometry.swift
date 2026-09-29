import Foundation

enum ImageZoomGeometry {
    static func fittedSize(image: CGSize, viewport: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / image.width, viewport.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    static func centeringInset(content: CGSize, viewport: CGSize) -> CGPoint {
        CGPoint(x: max(0, (viewport.width - content.width) / 2),
                y: max(0, (viewport.height - content.height) / 2))
    }
}
