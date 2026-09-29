// Run from the repository root: swift tools/generate_login_brand.swift
// Derive the login mark from the shipped icon, preserving its exact artwork.
// AppIcon's white foreground becomes the icon's pink on a transparent canvas.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let assets = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("ios-app/IbiliApp/Sources/Assets.xcassets")
let input = assets.appendingPathComponent("AppIcon.appiconset/ios-marketing-1024.png")
let output = assets.appendingPathComponent("LoginBrand.imageset/login-brand.png")
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Cannot read AppIcon") }
let width = image.width, height = image.height
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let flags = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: colorSpace, bitmapInfo: flags)!
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
let pink = [Double(pixels[0]), Double(pixels[1]), Double(pixels[2])]
precondition(pink[1] < 250, "AppIcon must have a pink background and white artwork")
var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width {
        let offset = (y * width + x) * 4
        let alpha = min(1, max(0, (Double(pixels[offset + 1]) - pink[1]) / (255 - pink[1])))
        for channel in 0..<3 { pixels[offset + channel] = UInt8((pink[channel] * alpha).rounded()) }
        pixels[offset + 3] = UInt8((255 * alpha).rounded())
        if pixels[offset + 3] > 0 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
precondition(minX < maxX && minY < maxY, "AppIcon must contain foreground artwork")
let cropped = context.makeImage()!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, cropped, nil)
precondition(CGImageDestinationFinalize(destination), "Cannot write LoginBrand")
print("LoginBrand: \(cropped.width) × \(cropped.height), transparent background, exact AppIcon artwork")
