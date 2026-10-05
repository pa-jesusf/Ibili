import CoreGraphics
import CoreImage
import Foundation

/// A small static image, generated on the image work queue. The blurred lower
/// edge extends into new space without reflecting the artwork; the cover itself
/// is never cropped or blurred. No live backdrop filter runs while scrolling.
enum ExtendedCoverBackdrop {
    static let pixelWidth = 160
    static let pixelHeight = 120
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let cache: NSCache<NSString, Bitmap> = {
        let cache = NSCache<NSString, Bitmap>()
        cache.countLimit = 96
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    private final class Bitmap {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    static func image(for source: CGImage, cacheKey: String) -> CGImage? {
        if let cached = cache.object(forKey: cacheKey as NSString) { return cached.image }
        guard let image = render(source) else { return nil }
        cache.setObject(Bitmap(image), forKey: cacheKey as NSString,
                        cost: image.bytesPerRow * image.height)
        return image
    }

    static func render(_ source: CGImage) -> CGImage? {
        let original = CIImage(cgImage: source)
        // A crop ending between source pixels introduces partial alpha that
        // blur can spread to the join, even when the source is opaque.
        let stripHeight = max(1, (original.extent.height * 0.25).rounded(.down))
        let strip = original.cropped(to: CGRect(x: 0, y: 0, width: original.extent.width, height: stripHeight))
        let size = CGSize(width: pixelWidth, height: pixelHeight)
        let bounds = CGRect(origin: .zero, size: size)
        // Core Image's origin is at the bottom. Put the cover's lower edge
        // at the extension's top, then clamp its colors into the space below.
        // Blur the whole extension, including that first row.
        let scale = size.width / strip.extent.width
        // Clamp before resampling: a fractional scaled edge can otherwise
        // become translucent and repeat as a dark line along the join.
        let extensionImage = strip.clampedToExtent().transformed(by: CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale, tx: 0, ty: size.height
        ))
        let output = extensionImage
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 18])
            .cropped(to: bounds)
        return context.createCGImage(output, from: bounds)
    }
}
