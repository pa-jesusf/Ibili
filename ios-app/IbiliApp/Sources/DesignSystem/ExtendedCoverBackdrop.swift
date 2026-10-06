import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// One continuous cover extension, rendered once off the main thread using
/// Apple's variable blur. Size and appearance participate in cache identity.
enum ExtendedCoverBackdrop {
    static let pixelWidth = 384
    static let transitionAspectRatio: CGFloat = 5 / 160

    struct Configuration: Hashable {
        var panelAspectRatio: CGFloat = 0.75
        var titleInsetRatio: CGFloat = 6 / 192
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0

        var pixelHeight: Int { min(2048, max(1, Int(ceil(CGFloat(pixelWidth) * (panelAspectRatio + transitionAspectRatio))))) }
        var cacheKey: String { "\(panelAspectRatio)-\(titleInsetRatio)-\(red)-\(green)-\(blue)" }
    }

    private static let context = CIContext(options: [.cacheIntermediates: false, .workingFormat: CIFormat.RGBAh,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
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

    static func image(for source: CGImage, cacheKey: String, configuration: Configuration) -> CGImage? {
        let key = "\(cacheKey)#\(configuration.cacheKey)" as NSString
        if let bitmap = cache.object(forKey: key) { return bitmap.image }
        guard let image = render(source, configuration: configuration) else { return nil }
        cache.setObject(Bitmap(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    static func render(_ source: CGImage, configuration: Configuration = .init()) -> CGImage? {
        let width = CGFloat(pixelWidth)
        let height = CGFloat(configuration.pixelHeight)
        let overlap = width * transitionAspectRatio
        let panelHeight = height - overlap
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let scale = width / CGFloat(source.width)
        let cover = CIImage(cgImage: source).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Clamp the bottom edge downward instead of mirroring the artwork.
        // Extra source rows above the join give the blur a continuous input.
        let strip = cover.cropped(to: CGRect(x: 0, y: 0, width: width,
                                             height: max(overlap, cover.extent.height / 4)))
        let extended = strip.clampedToExtent().transformed(by: CGAffineTransform(translationX: 0, y: panelHeight))
        let readableDistance = overlap + width * configuration.titleInsetRatio

        let firstFade = gradient(from: height, to: height - readableDistance, amount: 0.64)
        let remainingFade = gradient(from: height - readableDistance, to: 0, amount: 0.26)
        let tintMask = firstFade.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: remainingFade])
        let background = CIImage(color: CIColor(red: configuration.red, green: configuration.green,
                                                blue: configuration.blue)).cropped(to: bounds)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = background
        blend.backgroundImage = extended
        blend.maskImage = tintMask
        guard let faded = blend.outputImage else { return nil }

        let blur = CIFilter.maskedVariableBlur()
        blur.inputImage = faded.cropped(to: bounds).clampedToExtent()
        // Short panels must keep the same physical ramp. A negative endpoint
        // is valid; squeezing the ramp into their height blurs the title edge.
        blur.mask = gradient(from: height, to: height - 112, amount: 1)
        blur.radius = 36
        guard let blurred = blur.outputImage else { return nil }

        // Keep color precision until the final render. Apple's dither filter
        // reduces visible 8-bit quantization bands in dark gradients.
        let dither = CIFilter.dither()
        dither.inputImage = blurred.cropped(to: bounds)
        dither.intensity = 0.004
        guard let diffused = dither.outputImage else { return nil }
        let alpha = CIFilter.blendWithMask()
        alpha.inputImage = diffused
        alpha.backgroundImage = CIImage(color: .clear)
        alpha.maskImage = gradient(from: height, to: panelHeight, amount: 1)
        guard let output = alpha.outputImage else { return nil }
        return context.createCGImage(output, from: bounds, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false)
    }

    private static func gradient(from top: CGFloat, to bottom: CGFloat, amount: CGFloat) -> CIImage {
        let filter = CIFilter.smoothLinearGradient()
        filter.point0 = CGPoint(x: 0, y: top)
        filter.point1 = CGPoint(x: 0, y: bottom)
        filter.color0 = CIColor(red: 0, green: 0, blue: 0)
        filter.color1 = CIColor(red: amount, green: amount, blue: amount)
        return filter.outputImage!
    }
}
