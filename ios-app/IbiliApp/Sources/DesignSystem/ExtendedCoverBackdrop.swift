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

    enum SurfaceStyle: Hashable {
        case ambient, trailing
    }

    struct SurfaceConfiguration: Hashable {
        let width: CGFloat
        let height: CGFloat
        let style: SurfaceStyle
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        var scale: CGFloat { min(CGFloat(pixelWidth) / width, 768 / height) }
        var bounds: CGRect {
            CGRect(x: 0, y: 0, width: ceil(width * scale), height: ceil(height * scale))
        }
        var cacheKey: String { "\(width)-\(height)-\(style)-\(red)-\(green)-\(blue)" }
    }

    struct Artwork {
        let image: CGImage
        /// Actual visible image frame, with the card's top-left as origin.
        let frame: CGRect
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

    static func surface(for artwork: [Artwork], cacheKey: String, configuration: SurfaceConfiguration) -> CGImage? {
        let key = "surface#\(cacheKey)#\(configuration.cacheKey)" as NSString
        if let bitmap = cache.object(forKey: key) { return bitmap.image }
        guard let image = renderSurface(artwork, configuration: configuration) else { return nil }
        cache.setObject(Bitmap(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    static func renderSurface(_ artwork: [Artwork], configuration: SurfaceConfiguration) -> CGImage? {
        guard configuration.width.isFinite, configuration.height.isFinite,
              configuration.width > 0, configuration.height > 0, !artwork.isEmpty else { return nil }
        let bounds = configuration.bounds
        let base = CIImage(color: CIColor(red: configuration.red, green: configuration.green,
                                          blue: configuration.blue)).cropped(to: bounds)
        var samples: [(color: CIColor, image: CIImage, frame: CGRect, area: CGFloat)] = []
        for source in artwork {
            let visible = source.frame
            guard visible.width > 0, visible.height > 0, !visible.isNull, !visible.isInfinite,
                  visible.minX.isFinite, visible.minY.isFinite else { continue }
            let frame = CGRect(x: visible.minX * configuration.scale,
                               y: bounds.height - visible.maxY * configuration.scale,
                               width: visible.width * configuration.scale, height: visible.height * configuration.scale)
            let original = CIImage(cgImage: source.image)
            // Sample the same centered aspect-fill crop that is visible in the
            // foreground. Hidden edges must not decide a square tile's colors.
            let width = min(original.extent.width, original.extent.height * visible.width / visible.height)
            let height = min(original.extent.height, original.extent.width * visible.height / visible.width)
            let crop = CGRect(x: original.extent.midX - width / 2, y: original.extent.midY - height / 2,
                              width: width, height: height)
            guard let color = averageColor(original, extent: crop) else { continue }
            let scale = frame.width / crop.width
            let fitted = original.cropped(to: crop)
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: frame.minX - crop.minX * scale,
                                                   y: frame.minY - crop.minY * scale))
                .cropped(to: frame)
            samples.append((color, fitted, frame, frame.width * frame.height * color.alpha))
        }
        guard !samples.isEmpty else { return nil }
        let light = configuration.red * 0.2126 + configuration.green * 0.7152 + configuration.blue * 0.0722 > 0.5
        func palette(_ color: CIColor) -> CIImage {
            // Bound luminance so primary text keeps its contrast in either theme.
            let maximum = max(color.red, color.green, color.blue, 0.001)
            let floor: CGFloat = light ? 0.64 : 0.08
            let range: CGFloat = light ? 0.26 : 0.32
            return CIImage(color: CIColor(red: floor + range * color.red / maximum,
                                         green: floor + range * color.green / maximum,
                                         blue: floor + range * color.blue / maximum))
        }
        func tinted(_ background: CIImage, color: CIImage, mask: CIImage) -> CIImage? {
            let blend = CIFilter.blendWithMask()
            blend.inputImage = color
            blend.backgroundImage = background
            blend.maskImage = mask
            return blend.outputImage?.cropped(to: bounds)
        }
        let composed: CIImage
        if configuration.style == .trailing {
            let sample = samples[0]
            let fade = CIFilter.smoothLinearGradient()
            fade.point0 = CGPoint(x: sample.frame.midX, y: 0)
            fade.point1 = CGPoint(x: bounds.maxX, y: 0)
            fade.color0 = CIColor(red: 0.48, green: 0.48, blue: 0.48)
            fade.color1 = CIColor(red: 0.08, green: 0.08, blue: 0.08)
            guard let mask = fade.outputImage,
                  let output = tinted(base, color: palette(sample.color), mask: mask) else { return nil }
            composed = output
        } else {
            let area = samples.reduce(CGFloat.zero) { $0 + $1.area }
            let average = CIColor(red: samples.reduce(0) { $0 + $1.color.red * $1.area } / area,
                                  green: samples.reduce(0) { $0 + $1.color.green * $1.area } / area,
                                  blue: samples.reduce(0) { $0 + $1.color.blue * $1.area } / area)
            var canvas = CIImage(color: average).cropped(to: bounds)
            var footprint = CGRect.null
            var fade = CIImage(color: .black).cropped(to: bounds)
            for sample in samples {
                canvas = sample.image.composited(over: canvas)
                footprint = footprint.union(sample.frame)
                fade = surfaceFade(around: sample.frame, in: bounds)
                    .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: fade])
            }
            // Extend the actual image layout, then blur the whole canvas once.
            // Its spatial colors survive without separate blur bands or sharp
            // copies outside the foreground pictures.
            let blur = CIFilter.gaussianBlur()
            // Fractional crop edges let clamp sample transparency and create a
            // dark rim. Extend from complete pixels in the opaque canvas.
            blur.inputImage = canvas.cropped(to: footprint.intersection(bounds).integral).clampedToExtent()
            blur.radius = 42
            guard let blurred = blur.outputImage else { return nil }
            let tone = CIFilter.colorMatrix()
            tone.inputImage = blurred
            let gain: CGFloat = light ? 0.25 : 0.36
            let floor: CGFloat = light ? 0.70 : 0.04
            tone.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
            tone.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
            tone.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
            tone.biasVector = CIVector(x: floor, y: floor, z: floor, w: 0)
            guard let color = tone.outputImage,
                  let output = tinted(base, color: color, mask: fade) else { return nil }
            composed = output
        }
        let dither = CIFilter.dither()
        dither.inputImage = composed
        dither.intensity = 0.004
        guard let output = dither.outputImage else { return nil }
        // Transparent PNGs and filter precision must not make the card surface
        // translucent. The original image keeps its own alpha in the foreground.
        return context.createCGImage(output.composited(over: base), from: bounds, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false)
    }

    private static func surfaceFade(around frame: CGRect, in bounds: CGRect) -> CIImage {
        // Like the home card's extension, retain some artwork color throughout
        // the panel. Side edges don't need a vignette around the image.
        let below = gradient(from: CGPoint(x: 0, y: bounds.minY),
                             to: CGPoint(x: 0, y: max(bounds.minY + 1, frame.minY)),
                             amount: 1, startAmount: 0.22)
        let above = gradient(from: CGPoint(x: 0, y: bounds.maxY),
                             to: CGPoint(x: 0, y: min(bounds.maxY - 1, frame.maxY)),
                             amount: 1, startAmount: 0.22)
        return below.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: above])
            .cropped(to: bounds)
    }

    private static func averageColor(_ image: CIImage, extent: CGRect) -> CIColor? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = extent
        guard let output = filter.outputImage else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            context.render(output, toBitmap: $0.baseAddress!, rowBytes: 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        guard pixel.allSatisfy({ $0.isFinite }), pixel[3] > 0.001 else { return nil }
        func channel(_ index: Int) -> CGFloat { CGFloat(min(1, max(0, pixel[index] / pixel[3]))) }
        return CIColor(red: channel(0), green: channel(1), blue: channel(2), alpha: CGFloat(pixel[3]))
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
        gradient(from: CGPoint(x: 0, y: top), to: CGPoint(x: 0, y: bottom), amount: amount)
    }

    private static func gradient(from start: CGPoint, to end: CGPoint, amount: CGFloat, startAmount: CGFloat = 0) -> CIImage {
        let filter = CIFilter.smoothLinearGradient()
        filter.point0 = start
        filter.point1 = end
        filter.color0 = CIColor(red: startAmount, green: startAmount, blue: startAmount)
        filter.color1 = CIColor(red: amount, green: amount, blue: amount)
        return filter.outputImage!
    }
}
