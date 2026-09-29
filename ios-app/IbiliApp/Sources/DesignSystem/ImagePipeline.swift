import ImageIO
import UIKit

struct ImageRequestKey: Hashable {
    let url: URL
    let pixels: Int
    init(url: URL, maxPixelDimension: CGFloat) {
        self.url = url
        pixels = maxPixelDimension.isFinite ? max(1, Int(maxPixelDimension.rounded(.up))) : 1
    }
    var cacheKey: NSString { "\(url.absoluteString)#pixels=\(pixels)" as NSString }
}

/// Consumers share a URL/size request, but own their cancellation independently.
@MainActor
final class ImagePipeline {
    static let shared = ImagePipeline()
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>]
    }
    private var inFlight: [ImageRequestKey: Flight] = [:]
    private let loader: (ImageRequestKey) async -> UIImage?

    init(loader: @escaping (ImageRequestKey) async -> UIImage? = { await ImagePipeline.load($0) }) {
        self.loader = loader
    }

    static func displayPixelDimension(for pointSize: CGSize?) -> CGFloat {
        let scale = UIScreen.main.scale
        let screen = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * scale
        guard let pointSize else { return screen }
        return min(max(max(pointSize.width, pointSize.height) * scale, 160), screen)
    }

    func image(for url: URL, maxPixelDimension: CGFloat) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let key = ImageRequestKey(url: url, maxPixelDimension: maxPixelDimension)
        if let cached = ImageCache.shared.image(for: url, maxPixelDimension: CGFloat(key.pixels)) { return cached }
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: nil); return }
                if inFlight[key] != nil {
                    inFlight[key]?.waiters[waiter] = continuation
                    return
                }
                let id = UUID()
                let task = Task { [weak self, loader] in
                    let image = await loader(key)
                    guard let self, self.inFlight[key]?.id == id else { return }
                    let waiters = self.inFlight.removeValue(forKey: key)?.waiters.values
                    if let image, !Task.isCancelled {
                        ImageCache.shared.store(image, for: url, maxPixelDimension: CGFloat(key.pixels))
                    }
                    waiters?.forEach { $0.resume(returning: Task.isCancelled ? nil : image) }
                }
                inFlight[key] = Flight(id: id, task: task, waiters: [waiter: continuation])
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(waiter: waiter, key: key) }
        }
    }

    private func cancel(waiter: UUID, key: ImageRequestKey) {
        guard let continuation = inFlight[key]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: nil)
        if inFlight[key]?.waiters.isEmpty == true {
            inFlight.removeValue(forKey: key)?.task.cancel()
        }
    }

    private static func load(_ key: ImageRequestKey) async -> UIImage? {
        if let image = try? await BlockingWorkQueue.images.run(priority: .utility, {
            ImageDiskCache.shared.read(key.url).flatMap { downsampleData($0, maxPixelDimension: key.pixels) }
        }) { return image }
        for attempt in 0..<3 {
            guard !Task.isCancelled else { return nil }
            do {
                let (data, response) = try await URLSession.shared.data(from: key.url)
                try Task.checkCancellation()
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                let image = try await BlockingWorkQueue.images.run(priority: .utility) {
                    downsampleData(data, maxPixelDimension: key.pixels)
                }
                try Task.checkCancellation()
                if image != nil { ImageDiskCache.shared.write(key.url, data: data) }
                return image
            } catch is CancellationError { return nil }
            catch {
                guard !Task.isCancelled else { return nil }
                try? await Task.sleep(nanoseconds: UInt64(150_000_000 * (attempt + 1)))
            }
        }
        return nil
    }

    nonisolated static func downsampleData(_ data: Data, maxPixelDimension: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelDimension),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

}
